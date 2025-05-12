use aiken/collection/dict
use aiken/collection/list
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{from_script}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use constants.{pool_nft_tn}
use test_constants.{
  get_license_input_output, t_admin_pkh, t_collateral_asset,
  t_collateral_asset_ada, t_collateral_info, t_collateral_info_ada,
  t_init_pool_datum, t_init_pool_output, t_pool_authtoken_policy_id, t_pool_id,
  t_pool_info_nft, t_pool_nft, t_pool_outref, t_pool_script_hash,
  test_get_pool_info, test_get_pool_info_ada_collateral,
  test_get_pool_info_non_ada,
}
use types.{
  Asset, OBorrow, ODeposit, OLiquidate, ORepay, OWithdraw, OracleDatum,
  OrderDatum, PoolDatum, PoolInfoDatum, PoolParams, VaultDatum,
}
use utils.{
  cal_interest_rate, find_license_deadline, find_posix_time_range, multiplier,
  oracle_decimals, year_in_seconds,
}

pub type PoolRedeemer {
  ApplyDeposit {
    own_input_idx: Int,
    own_output_idx: Int,
    pool_info_idx: Int,
    license_idx: Int,
    order_indices: List<(Int, Int)>,
  }
  ApplyWithdraw {
    own_input_idx: Int,
    own_output_idx: Int,
    pool_info_idx: Int,
    license_idx: Int,
    order_indices: List<(Int, Int)>,
  }
  ApplyBorrow {
    own_input_idx: Int,
    own_output_idx: Int,
    pool_info_idx: Int,
    license_idx: Int,
    // (in_idx, out_idx, vault_idx, oracle_idx)
    order_indices: List<(Int, Int, Int, Int)>,
  }
  ApplyRepay {
    own_input_idx: Int,
    own_output_idx: Int,
    pool_info_idx: Int,
    license_idx: Int,
    // (in_idx, out_idx, vault_idx, oracle_idx)
    order_indices: List<(Int, Int, Int, Int)>,
  }
  ApplyLiquidate {
    own_input_idx: Int,
    own_output_idx: Int,
    pool_info_idx: Int,
    license_idx: Int,
    // (in_idx, vault_idx, oracle_idx)
    order_indices: List<(Int, Int, Int)>,
  }
  Close
}

validator pool(params: PoolParams) {
  spend(
    option_datum: Option<PoolDatum>,
    redeemer: PoolRedeemer,
    _utxo: OutputReference,
    self: Transaction,
  ) {
    let Transaction {
      inputs,
      reference_inputs,
      outputs,
      mint,
      extra_signatories,
      validity_range,
      ..
    } = self
    when redeemer is {
      ApplyDeposit {
        own_input_idx,
        own_output_idx,
        license_idx,
        pool_info_idx,
        order_indices,
      } -> {
        expect Some(datum) = option_datum
        let own_input_datum: PoolDatum = datum
        expect Some(own_input) = list.at(inputs, own_input_idx)
        expect Some(own_output) = list.at(outputs, own_output_idx)
        expect own_input.output.address == own_output.address
        expect InlineDatum(own_output_inline_datum) = own_output.datum
        expect own_output_datum: PoolDatum = own_output_inline_datum
        expect own_input_datum.pool_id == own_output_datum.pool_id
        expect
          assets.quantity_of(
            own_input.output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect
          assets.quantity_of(
            own_output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect Some(pool_info_ref_input) =
          list.at(reference_inputs, pool_info_idx)
        expect
          assets.quantity_of(
            pool_info_ref_input.output.value,
            params.pool_info_nft.policy_id,
            params.pool_info_nft.asset_name,
          ) == 1
        expect InlineDatum(pool_info_inline_datum) =
          pool_info_ref_input.output.datum
        expect pool_info_datum: PoolInfoDatum = pool_info_inline_datum
        expect pool_info_datum.pool_id == own_input_datum.pool_id
        expect Some(Input { output: Output { value: batcher_value, .. }, .. }) =
          list.at(inputs, license_idx)
        let license_deadline =
          find_license_deadline(
            pool_info_datum.batcher_policy_id,
            batcher_value,
          )
        let (_start_valid_time_range, end_valid_time_range) =
          find_posix_time_range(validity_range)
        expect license_deadline >= end_valid_time_range
        let (total_deposit, total_payment, _prev_out) =
          list.foldl(
            order_indices,
            (0, 0, -1),
            fn(curr, acc) {
              let (in_idx, out_idx) = curr
              let (acc_total, acc_payment, p_out) = acc
              expect out_idx > p_out
              expect Some(in) = list.at(inputs, in_idx)
              expect Some(out) = list.at(outputs, out_idx)
              expect InlineDatum(order_inline_datum) = in.output.datum
              expect order_datum: OrderDatum = order_inline_datum
              when order_datum is {
                ODeposit {
                  o_pool_id,
                  o_owner_pkh,
                  o_owner_stake_key,
                  o_amount,
                  o_batcher_fee,
                } -> {
                  expect o_pool_id == own_input_datum.pool_id
                  let user_address =
                    when o_owner_stake_key is {
                      Some(key) ->
                        address.from_verification_key(o_owner_pkh)
                          |> address.with_delegation_key(key)
                      None -> address.from_verification_key(o_owner_pkh)
                    }
                  expect user_address == out.address
                  expect o_amount > 0 && o_batcher_fee >= 0
                  let min_lovelace =
                    o_batcher_fee + pool_info_datum.envelope_amount
                  let payment =
                    when own_input_datum.total_ctoken == 0 is {
                      True -> o_amount * pool_info_datum.pool_asset_decimals
                      False ->
                        o_amount * own_input_datum.total_supplied / own_input_datum.total_ctoken
                    }
                  let in_lovelace = assets.lovelace_of(in.output.value)
                  expect
                    when
                      pool_info_datum.pool_asset.policy_id == assets.ada_policy_id
                    is {
                      True ->
                        in_lovelace >= min_lovelace + payment && list.length(
                          assets.flatten(in.output.value),
                        ) == 1
                      False ->
                        in_lovelace >= min_lovelace && assets.quantity_of(
                          in.output.value,
                          pool_info_datum.pool_asset.policy_id,
                          pool_info_datum.pool_asset.asset_name,
                        ) >= payment && list.length(
                          assets.flatten(in.output.value),
                        ) == 2
                    }
                  expect
                    assets.flatten(out.value) == [
                      (
                        assets.ada_policy_id,
                        assets.ada_asset_name,
                        pool_info_datum.envelope_amount,
                      ),
                      (
                        pool_info_datum.ctoken.policy_id,
                        pool_info_datum.ctoken.asset_name,
                        o_amount,
                      ),
                    ]
                  (acc_total + o_amount, acc_payment + payment, out_idx)
                }
                _ -> fail
              }
            },
          )
        expect
          assets.flatten(mint) == [
            (
              pool_info_datum.ctoken.policy_id,
              pool_info_datum.ctoken.asset_name,
              total_deposit,
            ),
          ]
        expect
          own_output_datum.total_ctoken == own_input_datum.total_ctoken + total_deposit
        expect
          own_output_datum.total_supplied == own_input_datum.total_supplied + total_payment
        expect own_output_datum.total_borrowed == own_input_datum.total_borrowed
        expect own_output_datum.reserve == own_input_datum.reserve
        when pool_info_datum.pool_asset.policy_id == assets.ada_policy_id is {
          True -> {
            expect list.length(assets.flatten(own_output.value)) == 2
            assets.lovelace_of(own_output.value) == assets.lovelace_of(
              own_input.output.value,
            ) + total_payment
          }
          False -> {
            expect list.length(assets.flatten(own_output.value)) == 3
            expect
              assets.lovelace_of(own_output.value) == assets.lovelace_of(
                own_input.output.value,
              )
            assets.quantity_of(
              own_output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) == assets.quantity_of(
              own_input.output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) + total_payment
          }
        }
      }
      ApplyWithdraw {
        own_input_idx,
        own_output_idx,
        license_idx,
        pool_info_idx,
        order_indices,
      } -> {
        expect Some(datum) = option_datum
        let own_input_datum: PoolDatum = datum
        expect Some(own_input) = list.at(inputs, own_input_idx)
        expect Some(own_output) = list.at(outputs, own_output_idx)
        expect own_input.output.address == own_output.address
        expect InlineDatum(own_output_inline_datum) = own_output.datum
        expect own_output_datum: PoolDatum = own_output_inline_datum
        expect own_input_datum.pool_id == own_output_datum.pool_id
        expect
          assets.quantity_of(
            own_input.output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect
          assets.quantity_of(
            own_output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect Some(pool_info_ref_input) =
          list.at(reference_inputs, pool_info_idx)
        expect
          assets.quantity_of(
            pool_info_ref_input.output.value,
            params.pool_info_nft.policy_id,
            params.pool_info_nft.asset_name,
          ) == 1
        expect InlineDatum(pool_info_inline_datum) =
          pool_info_ref_input.output.datum
        expect pool_info_datum: PoolInfoDatum = pool_info_inline_datum
        expect pool_info_datum.pool_id == own_input_datum.pool_id
        expect Some(Input { output: Output { value: batcher_value, .. }, .. }) =
          list.at(inputs, license_idx)
        let license_deadline =
          find_license_deadline(
            pool_info_datum.batcher_policy_id,
            batcher_value,
          )
        let (_start_valid_time_range, end_valid_time_range) =
          find_posix_time_range(validity_range)
        expect license_deadline >= end_valid_time_range
        let (total_withdraw, total_payment, _prev_out) =
          list.foldl(
            order_indices,
            (0, 0, -1),
            fn(curr, acc) {
              let (in_idx, out_idx) = curr
              let (acc_total, acc_payment, p_out) = acc
              expect out_idx > p_out
              expect Some(in) = list.at(inputs, in_idx)
              expect Some(out) = list.at(outputs, out_idx)
              expect InlineDatum(order_inline_datum) = in.output.datum
              expect order_datum: OrderDatum = order_inline_datum
              when order_datum is {
                OWithdraw {
                  o_pool_id,
                  o_owner_pkh,
                  o_owner_stake_key,
                  o_amount,
                  o_batcher_fee,
                } -> {
                  expect o_pool_id == own_input_datum.pool_id
                  let user_address =
                    when o_owner_stake_key is {
                      Some(key) ->
                        address.from_verification_key(o_owner_pkh)
                          |> address.with_delegation_key(key)
                      None -> address.from_verification_key(o_owner_pkh)
                    }
                  expect user_address == out.address
                  expect o_amount > 0 && o_batcher_fee >= 0
                  let min_lovelace =
                    o_batcher_fee + pool_info_datum.envelope_amount
                  let payment =
                    o_amount * own_input_datum.total_supplied / own_input_datum.total_ctoken
                  let in_lovelace = assets.lovelace_of(in.output.value)
                  expect in_lovelace >= min_lovelace
                  expect list.length(assets.flatten(in.output.value)) == 2
                  expect
                    assets.quantity_of(
                      in.output.value,
                      pool_info_datum.ctoken.policy_id,
                      pool_info_datum.ctoken.asset_name,
                    ) == o_amount
                  expect
                    when
                      pool_info_datum.pool_asset.policy_id == assets.ada_policy_id
                    is {
                      True -> {
                        expect
                          assets.flatten(out.value) == [
                            (
                              assets.ada_policy_id,
                              assets.ada_asset_name,
                              pool_info_datum.envelope_amount + payment,
                            ),
                          ]
                        True
                      }
                      False -> {
                        expect
                          assets.flatten(out.value) == [
                            (
                              assets.ada_policy_id,
                              assets.ada_asset_name,
                              pool_info_datum.envelope_amount,
                            ),
                            (
                              pool_info_datum.pool_asset.policy_id,
                              pool_info_datum.pool_asset.asset_name,
                              payment,
                            ),
                          ]
                        True
                      }
                    }
                  (acc_total + o_amount, acc_payment + payment, out_idx)
                }
                _ -> fail
              }
            },
          )
        expect
          assets.flatten(mint) == [
            (
              pool_info_datum.ctoken.policy_id,
              pool_info_datum.ctoken.asset_name,
              -total_withdraw,
            ),
          ]
        expect
          own_output_datum.total_ctoken == own_input_datum.total_ctoken - total_withdraw
        expect
          own_output_datum.total_supplied == own_input_datum.total_supplied - total_payment
        expect own_output_datum.total_borrowed == own_input_datum.total_borrowed
        expect own_output_datum.reserve == own_input_datum.reserve
        when pool_info_datum.pool_asset.policy_id == assets.ada_policy_id is {
          True -> {
            expect list.length(assets.flatten(own_output.value)) == 2
            assets.lovelace_of(own_output.value) == assets.lovelace_of(
              own_input.output.value,
            ) - total_payment
          }
          False -> {
            expect list.length(assets.flatten(own_output.value)) == 3
            expect
              assets.lovelace_of(own_output.value) == assets.lovelace_of(
                own_input.output.value,
              )
            assets.quantity_of(
              own_output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) == assets.quantity_of(
              own_input.output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) - total_payment
          }
        }
      }
      ApplyBorrow {
        own_input_idx,
        own_output_idx,
        pool_info_idx,
        license_idx,
        order_indices,
      } -> {
        expect Some(datum) = option_datum
        let own_input_datum: PoolDatum = datum
        expect Some(own_input) = list.at(inputs, own_input_idx)
        expect Some(own_output) = list.at(outputs, own_output_idx)
        expect own_input.output.address == own_output.address
        expect InlineDatum(own_output_inline_datum) = own_output.datum
        expect own_output_datum: PoolDatum = own_output_inline_datum
        expect own_input_datum.pool_id == own_output_datum.pool_id
        expect
          assets.quantity_of(
            own_input.output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect
          assets.quantity_of(
            own_output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect Some(pool_info_ref_input) =
          list.at(reference_inputs, pool_info_idx)
        expect
          assets.quantity_of(
            pool_info_ref_input.output.value,
            params.pool_info_nft.policy_id,
            params.pool_info_nft.asset_name,
          ) == 1
        expect InlineDatum(pool_info_inline_datum) =
          pool_info_ref_input.output.datum
        expect pool_info_datum: PoolInfoDatum = pool_info_inline_datum
        expect pool_info_datum.pool_id == own_input_datum.pool_id
        expect Some(Input { output: Output { value: batcher_value, .. }, .. }) =
          list.at(inputs, license_idx)
        let license_deadline =
          find_license_deadline(
            pool_info_datum.batcher_policy_id,
            batcher_value,
          )
        let (start_valid_time_range, end_valid_time_range) =
          find_posix_time_range(validity_range)
        expect license_deadline >= end_valid_time_range
        let (total_borrow, total_payment, _prev_out, count) =
          list.foldl(
            order_indices,
            (0, 0, -1, 0),
            fn(curr, acc) {
              let (in_idx, out_idx, vault_idx, oracle_idx) = curr
              let (acc_total, acc_payment, p_out, c_count) = acc
              expect out_idx > p_out
              expect Some(in) = list.at(inputs, in_idx)
              expect InlineDatum(order_inline_datum) = in.output.datum
              expect order_datum: OrderDatum = order_inline_datum
              expect Some(out) = list.at(outputs, out_idx)
              expect Some(out_vault) = list.at(outputs, vault_idx)
              expect InlineDatum(vault_inline_datum) = out_vault.datum
              expect vault_datum: VaultDatum = vault_inline_datum
              expect Some(oracle_ref_input) =
                list.at(reference_inputs, oracle_idx)
              expect InlineDatum(oracle_inline_datum) =
                oracle_ref_input.output.datum
              expect oracle_datum: OracleDatum = oracle_inline_datum
              when order_datum is {
                OBorrow {
                  o_pool_id,
                  o_owner_pkh,
                  o_owner_stake_key,
                  o_principal,
                  o_batcher_fee,
                  o_collateral_amount,
                  o_collateral_asset,
                } -> {
                  expect o_pool_id == own_input_datum.pool_id
                  expect o_principal > 0 && o_batcher_fee >= 0
                  expect Some(collateral_info) =
                    list.find(
                      pool_info_datum.collateral_infos,
                      fn(c_info) {
                        o_collateral_asset == c_info.collateral_asset && assets.quantity_of(
                          oracle_ref_input.output.value,
                          c_info.oracle_nft.policy_id,
                          c_info.oracle_nft.asset_name,
                        ) == 1
                      },
                    )
                  let ltv =
                    o_principal * pool_info_datum.pool_asset_decimals * multiplier / (
                      o_collateral_amount * collateral_info.collateral_decimals * oracle_datum.price / oracle_decimals
                    )
                  expect ltv <= collateral_info.liquidation_threshold
                  expect ltv <= collateral_info.max_borrow_ltv
                  let user_address =
                    when o_owner_stake_key is {
                      Some(key) ->
                        address.from_verification_key(o_owner_pkh)
                          |> address.with_delegation_key(key)
                      None -> address.from_verification_key(o_owner_pkh)
                    }
                  expect out.address == user_address
                  let vault_address =
                    when pool_info_datum.pool_stake_key is {
                      Some(key) ->
                        address.from_script(pool_info_datum.vault_script_hash)
                          |> address.with_delegation_script(key)
                      None ->
                        address.from_script(pool_info_datum.vault_script_hash)
                    }
                  expect vault_datum.pool_id == own_input_datum.pool_id
                  expect vault_datum.borrow_id == in.output_reference
                  expect vault_datum.owner_pkh == o_owner_pkh
                  expect vault_datum.owner_stake_key == o_owner_stake_key
                  expect vault_datum.collateral_asset == o_collateral_asset
                  expect vault_datum.collateral_amount == o_collateral_amount
                  expect
                    vault_datum.collateral_decimals == collateral_info.collateral_decimals
                  expect vault_datum.start_time <= start_valid_time_range
                  expect vault_datum.principal == o_principal
                  expect vault_address == out_vault.address
                  let u =
                    own_input_datum.total_borrowed * multiplier / own_input_datum.total_supplied
                  let interest_rate = cal_interest_rate(u, pool_info_datum)
                  expect vault_datum.interest_rate == interest_rate
                  let min_lovelace =
                    o_batcher_fee + pool_info_datum.envelope_amount * 2
                  let payment =
                    o_principal * pool_info_datum.pool_asset_decimals
                  let in_lovelace = assets.lovelace_of(in.output.value)
                  expect
                    assets.quantity_of(
                      out_vault.value,
                      pool_info_datum.vault_authtoken.policy_id,
                      pool_info_datum.vault_authtoken.asset_name,
                    ) == 1
                  expect in_lovelace >= min_lovelace
                  expect
                    when
                      collateral_info.collateral_asset.policy_id == assets.ada_policy_id
                    is {
                      True -> {
                        expect
                          assets.lovelace_of(in.output.value) >= min_lovelace + o_collateral_amount * collateral_info.collateral_decimals
                        expect
                          assets.lovelace_of(out_vault.value) >= pool_info_datum.envelope_amount + o_collateral_amount * collateral_info.collateral_decimals
                        list.length(assets.flatten(out_vault.value)) == 2
                      }
                      False -> {
                        expect
                          assets.quantity_of(
                            in.output.value,
                            o_collateral_asset.policy_id,
                            o_collateral_asset.asset_name,
                          ) >= o_collateral_amount * collateral_info.collateral_decimals
                        expect
                          assets.lovelace_of(out_vault.value) >= pool_info_datum.envelope_amount
                        expect
                          assets.quantity_of(
                            out_vault.value,
                            o_collateral_asset.policy_id,
                            o_collateral_asset.asset_name,
                          ) >= o_collateral_amount * collateral_info.collateral_decimals
                        list.length(assets.flatten(out_vault.value)) == 3
                      }
                    }
                  expect
                    when
                      pool_info_datum.pool_asset.policy_id == assets.ada_policy_id
                    is {
                      True ->
                        assets.flatten(out.value) == [
                          (
                            assets.ada_policy_id,
                            assets.ada_asset_name,
                            pool_info_datum.envelope_amount + payment,
                          ),
                        ]
                      False ->
                        assets.flatten(out.value) == [
                          (
                            assets.ada_policy_id,
                            assets.ada_asset_name,
                            pool_info_datum.envelope_amount,
                          ),
                          (
                            pool_info_datum.pool_asset.policy_id,
                            pool_info_datum.pool_asset.asset_name,
                            payment,
                          ),
                        ]
                    }
                  (
                    acc_total + o_principal,
                    acc_payment + payment,
                    out_idx,
                    c_count + 1,
                  )
                }
                _ -> fail
              }
            },
          )
        expect
          assets.flatten(mint) == [
            (
              pool_info_datum.vault_authtoken.policy_id,
              pool_info_datum.vault_authtoken.asset_name,
              count,
            ),
          ]
        expect own_output_datum.total_ctoken == own_input_datum.total_ctoken
        expect own_output_datum.total_supplied == own_input_datum.total_supplied
        expect
          own_output_datum.total_borrowed == own_input_datum.total_borrowed + total_borrow * pool_info_datum.pool_asset_decimals
        expect own_output_datum.reserve == own_input_datum.reserve
        when pool_info_datum.pool_asset.policy_id == assets.ada_policy_id is {
          True -> {
            expect list.length(assets.flatten(own_output.value)) == 2
            assets.lovelace_of(own_output.value) == assets.lovelace_of(
              own_input.output.value,
            ) - total_payment
          }
          False -> {
            expect list.length(assets.flatten(own_output.value)) == 3
            expect
              assets.lovelace_of(own_output.value) == assets.lovelace_of(
                own_input.output.value,
              )
            assets.quantity_of(
              own_output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) == assets.quantity_of(
              own_input.output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) - total_payment
          }
        }
      }
      ApplyRepay {
        own_input_idx,
        own_output_idx,
        pool_info_idx,
        license_idx,
        order_indices,
      } -> {
        expect Some(datum) = option_datum
        let own_input_datum: PoolDatum = datum
        expect Some(own_input) = list.at(inputs, own_input_idx)
        expect Some(own_output) = list.at(outputs, own_output_idx)
        expect own_input.output.address == own_output.address
        expect InlineDatum(own_output_inline_datum) = own_output.datum
        expect own_output_datum: PoolDatum = own_output_inline_datum
        expect own_input_datum.pool_id == own_output_datum.pool_id
        expect
          assets.quantity_of(
            own_input.output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect
          assets.quantity_of(
            own_output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect Some(pool_info_ref_input) =
          list.at(reference_inputs, pool_info_idx)
        expect
          assets.quantity_of(
            pool_info_ref_input.output.value,
            params.pool_info_nft.policy_id,
            params.pool_info_nft.asset_name,
          ) == 1
        expect InlineDatum(pool_info_inline_datum) =
          pool_info_ref_input.output.datum
        expect pool_info_datum: PoolInfoDatum = pool_info_inline_datum
        expect pool_info_datum.pool_id == own_input_datum.pool_id
        expect Some(Input { output: Output { value: batcher_value, .. }, .. }) =
          list.at(inputs, license_idx)
        let license_deadline =
          find_license_deadline(
            pool_info_datum.batcher_policy_id,
            batcher_value,
          )
        let (_start_valid_time_range, end_valid_time_range) =
          find_posix_time_range(validity_range)
        expect license_deadline >= end_valid_time_range
        let (total_repay, total_payment, _prev_out, count) =
          list.foldl(
            order_indices,
            (0, 0, -1, 0),
            fn(curr, acc) {
              let (in_idx, out_idx, vault_idx, oracle_idx) = curr
              let (acc_total, acc_payment, p_out, c_count) = acc
              expect out_idx > p_out
              expect Some(in) = list.at(inputs, in_idx)
              expect InlineDatum(order_inline_datum) = in.output.datum
              expect order_datum: OrderDatum = order_inline_datum
              expect Some(out) = list.at(outputs, out_idx)
              expect Some(in_vault) = list.at(inputs, vault_idx)
              let out_vault = in_vault.output
              expect
                assets.quantity_of(
                  out_vault.value,
                  pool_info_datum.vault_authtoken.policy_id,
                  pool_info_datum.vault_authtoken.asset_name,
                ) == 1
              expect InlineDatum(vault_inline_datum) = out_vault.datum
              expect vault_datum: VaultDatum = vault_inline_datum
              expect Some(oracle_ref_input) =
                list.at(reference_inputs, oracle_idx)
              expect InlineDatum(oracle_inline_datum) =
                oracle_ref_input.output.datum
              expect oracle_datum: OracleDatum = oracle_inline_datum
              when order_datum is {
                ORepay {
                  o_pool_id,
                  o_batcher_fee,
                  o_borrow_id,
                  o_owner_pkh,
                  o_time,
                } -> {
                  expect o_pool_id == own_input_datum.pool_id
                  expect o_batcher_fee >= 0
                  expect o_time > vault_datum.start_time
                  expect vault_datum.borrow_id == o_borrow_id
                  expect vault_datum.owner_pkh == o_owner_pkh
                  expect vault_datum.pool_id == own_input_datum.pool_id
                  expect Some(collateral_info) =
                    list.find(
                      pool_info_datum.collateral_infos,
                      fn(c_info) {
                        vault_datum.collateral_asset == c_info.collateral_asset && assets.quantity_of(
                          oracle_ref_input.output.value,
                          c_info.oracle_nft.policy_id,
                          c_info.oracle_nft.asset_name,
                        ) == 1
                      },
                    )
                  let payment =
                    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
                      multiplier + vault_datum.interest_rate * (
                        end_valid_time_range - vault_datum.start_time
                      ) / year_in_seconds
                    ) / multiplier
                  let ltv =
                    payment * multiplier / (
                      vault_datum.collateral_amount * collateral_info.collateral_decimals * oracle_datum.price / oracle_decimals
                    )
                  expect ltv < collateral_info.liquidation_threshold
                  let user_address =
                    when vault_datum.owner_stake_key is {
                      Some(key) ->
                        address.from_verification_key(vault_datum.owner_pkh)
                          |> address.with_delegation_key(key)
                      None ->
                        address.from_verification_key(vault_datum.owner_pkh)
                    }
                  expect out.address == user_address
                  let vault_address =
                    when pool_info_datum.pool_stake_key is {
                      Some(key) ->
                        address.from_script(pool_info_datum.vault_script_hash)
                          |> address.with_delegation_script(key)
                      None ->
                        address.from_script(pool_info_datum.vault_script_hash)
                    }
                  expect vault_address == out_vault.address
                  let min_lovelace =
                    o_batcher_fee + pool_info_datum.envelope_amount
                  let in_lovelace = assets.lovelace_of(in.output.value)
                  expect in_lovelace >= min_lovelace
                  expect
                    when
                      collateral_info.collateral_asset.policy_id == assets.ada_policy_id
                    is {
                      True -> {
                        expect
                          assets.lovelace_of(out.value) >= pool_info_datum.envelope_amount + vault_datum.collateral_amount * collateral_info.collateral_decimals
                        expect list.length(assets.flatten(out.value)) == 1
                        expect
                          assets.lovelace_of(out_vault.value) >= pool_info_datum.envelope_amount + vault_datum.collateral_amount * collateral_info.collateral_decimals
                        list.length(assets.flatten(out_vault.value)) == 2
                      }
                      False -> {
                        expect
                          assets.lovelace_of(out.value) >= pool_info_datum.envelope_amount
                        expect
                          assets.quantity_of(
                            out.value,
                            vault_datum.collateral_asset.policy_id,
                            vault_datum.collateral_asset.asset_name,
                          ) >= vault_datum.collateral_amount * collateral_info.collateral_decimals
                        expect list.length(assets.flatten(out.value)) == 2
                        expect
                          assets.lovelace_of(out_vault.value) >= pool_info_datum.envelope_amount
                        expect
                          assets.quantity_of(
                            out_vault.value,
                            vault_datum.collateral_asset.policy_id,
                            vault_datum.collateral_asset.asset_name,
                          ) >= vault_datum.collateral_amount * collateral_info.collateral_decimals
                        list.length(assets.flatten(out_vault.value)) == 3
                      }
                    }
                  expect
                    assets.quantity_of(
                      in.output.value,
                      pool_info_datum.pool_asset.policy_id,
                      pool_info_datum.pool_asset.asset_name,
                    ) >= vault_datum.principal * pool_info_datum.pool_asset_decimals * (
                      multiplier + vault_datum.interest_rate * (
                        o_time - vault_datum.start_time
                      ) / year_in_seconds
                    ) / multiplier
                  expect
                    when
                      pool_info_datum.pool_asset.policy_id == assets.ada_policy_id
                    is {
                      True -> list.length(assets.flatten(in.output.value)) == 1
                      False -> list.length(assets.flatten(in.output.value)) == 2
                    }
                  (
                    acc_total + vault_datum.principal,
                    acc_payment + payment,
                    out_idx,
                    c_count + 1,
                  )
                }
                _ -> fail
              }
            },
          )
        expect
          assets.flatten(mint) == [
            (
              pool_info_datum.vault_authtoken.policy_id,
              pool_info_datum.vault_authtoken.asset_name,
              -count,
            ),
          ]
        expect own_output_datum.total_ctoken == own_input_datum.total_ctoken
        let profit =
          total_payment - total_repay * pool_info_datum.pool_asset_decimals
        let add_to_reserve =
          profit * pool_info_datum.reserve_factor_percentage / multiplier
        expect
          own_output_datum.total_supplied == own_input_datum.total_supplied + (
            profit - add_to_reserve
          )
        expect
          own_output_datum.total_borrowed == own_input_datum.total_borrowed - total_repay * pool_info_datum.pool_asset_decimals
        expect
          own_output_datum.reserve == own_input_datum.reserve + add_to_reserve
        when pool_info_datum.pool_asset.policy_id == assets.ada_policy_id is {
          True -> {
            expect list.length(assets.flatten(own_output.value)) == 2
            assets.lovelace_of(own_output.value) == assets.lovelace_of(
              own_input.output.value,
            ) + total_payment
          }
          False -> {
            expect list.length(assets.flatten(own_output.value)) == 3
            expect
              assets.lovelace_of(own_output.value) == assets.lovelace_of(
                own_input.output.value,
              )
            assets.quantity_of(
              own_output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) == assets.quantity_of(
              own_input.output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) + total_payment
          }
        }
      }
      ApplyLiquidate {
        own_input_idx,
        own_output_idx,
        pool_info_idx,
        license_idx,
        order_indices,
      } -> {
        expect Some(datum) = option_datum
        let own_input_datum: PoolDatum = datum
        expect Some(own_input) = list.at(inputs, own_input_idx)
        expect Some(own_output) = list.at(outputs, own_output_idx)
        expect own_input.output.address == own_output.address
        expect InlineDatum(own_output_inline_datum) = own_output.datum
        expect own_output_datum: PoolDatum = own_output_inline_datum
        expect own_input_datum.pool_id == own_output_datum.pool_id
        expect
          assets.quantity_of(
            own_input.output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect
          assets.quantity_of(
            own_output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        expect Some(pool_info_ref_input) =
          list.at(reference_inputs, pool_info_idx)
        expect
          assets.quantity_of(
            pool_info_ref_input.output.value,
            params.pool_info_nft.policy_id,
            params.pool_info_nft.asset_name,
          ) == 1
        expect InlineDatum(pool_info_inline_datum) =
          pool_info_ref_input.output.datum
        expect pool_info_datum: PoolInfoDatum = pool_info_inline_datum
        expect pool_info_datum.pool_id == own_input_datum.pool_id
        expect Some(Input { output: Output { value: batcher_value, .. }, .. }) =
          list.at(inputs, license_idx)
        let license_deadline =
          find_license_deadline(
            pool_info_datum.batcher_policy_id,
            batcher_value,
          )
        let (_start_valid_time_range, end_valid_time_range) =
          find_posix_time_range(validity_range)
        expect license_deadline >= end_valid_time_range
        let (total_repay, total_payment) =
          list.foldl(
            order_indices,
            (0, 0),
            fn(curr, acc) {
              let (in_idx, vault_idx, oracle_idx) = curr
              let (acc_total, acc_payment) = acc
              expect Some(in) = list.at(inputs, in_idx)
              expect InlineDatum(order_inline_datum) = in.output.datum
              expect order_datum: OrderDatum = order_inline_datum
              expect Some(in_vault) = list.at(inputs, vault_idx)
              let out_vault = in_vault.output
              expect InlineDatum(vault_inline_datum) = out_vault.datum
              expect vault_datum: VaultDatum = vault_inline_datum
              expect Some(oracle_ref_input) =
                list.at(reference_inputs, oracle_idx)
              expect InlineDatum(oracle_inline_datum) =
                oracle_ref_input.output.datum
              expect oracle_datum: OracleDatum = oracle_inline_datum
              when order_datum is {
                OLiquidate { o_pool_id, o_batcher_fee, o_borrow_id, .. } -> {
                  expect o_pool_id == own_input_datum.pool_id
                  expect o_batcher_fee >= 0
                  expect vault_datum.borrow_id == o_borrow_id
                  expect vault_datum.pool_id == own_input_datum.pool_id
                  expect Some(collateral_info) =
                    list.find(
                      pool_info_datum.collateral_infos,
                      fn(c_info) {
                        vault_datum.collateral_asset == c_info.collateral_asset && assets.quantity_of(
                          oracle_ref_input.output.value,
                          c_info.oracle_nft.policy_id,
                          c_info.oracle_nft.asset_name,
                        ) == 1
                      },
                    )
                  let payment =
                    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
                      multiplier + vault_datum.interest_rate * (
                        end_valid_time_range - vault_datum.start_time
                      ) / year_in_seconds
                    ) / multiplier
                  let ltv =
                    payment * multiplier / (
                      vault_datum.collateral_amount * oracle_datum.price
                    )
                  expect ltv >= collateral_info.liquidation_threshold
                  let vault_address =
                    when pool_info_datum.pool_stake_key is {
                      Some(key) ->
                        address.from_script(pool_info_datum.vault_script_hash)
                          |> address.with_delegation_script(key)
                      None ->
                        address.from_script(pool_info_datum.vault_script_hash)
                    }
                  expect vault_address == out_vault.address
                  let min_lovelace =
                    o_batcher_fee + pool_info_datum.envelope_amount
                  let in_lovelace = assets.lovelace_of(in.output.value)
                  expect in_lovelace >= min_lovelace
                  expect
                    when
                      pool_info_datum.pool_asset.policy_id == assets.ada_policy_id
                    is {
                      True ->
                        assets.flatten(in.output.value) == [
                          (
                            assets.ada_policy_id,
                            assets.ada_asset_name,
                            min_lovelace + payment,
                          ),
                        ]
                      False -> {
                        expect
                          assets.quantity_of(
                            in.output.value,
                            pool_info_datum.pool_asset.policy_id,
                            pool_info_datum.pool_asset.asset_name,
                          ) >= payment
                        list.length(assets.flatten(in.output.value)) == 2
                      }
                    }
                  (acc_total + vault_datum.principal, acc_payment + payment)
                }
                _ -> fail
              }
            },
          )
        expect own_output_datum.total_ctoken == own_input_datum.total_ctoken
        let profit =
          total_payment - total_repay * pool_info_datum.pool_asset_decimals
        let add_to_reserve =
          profit * pool_info_datum.reserve_factor_percentage / multiplier
        expect
          own_output_datum.total_supplied == own_input_datum.total_supplied + (
            profit - add_to_reserve
          )
        expect
          own_output_datum.total_borrowed == own_input_datum.total_borrowed - total_repay * pool_info_datum.pool_asset_decimals
        expect
          own_output_datum.reserve == own_input_datum.reserve + add_to_reserve
        when pool_info_datum.pool_asset.policy_id == assets.ada_policy_id is {
          True -> {
            expect list.length(assets.flatten(own_output.value)) == 2
            assets.lovelace_of(own_output.value) == assets.lovelace_of(
              own_input.output.value,
            ) + total_payment
          }
          False -> {
            expect list.length(assets.flatten(own_output.value)) == 3
            expect
              assets.lovelace_of(own_output.value) == assets.lovelace_of(
                own_input.output.value,
              )
            assets.quantity_of(
              own_output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) == assets.quantity_of(
              own_input.output.value,
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
            ) + total_payment
          }
        }
      }
      Close -> list.has(extra_signatories, params.admin_pkh)
    }
  }

  else(_) {
    fail
  }
}

test pool_spend_apply_deposit() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let (license_input, license_output) = get_license_input_output()
  let pool_input =
    Input { output_reference: t_pool_outref, output: t_init_pool_output }
  let deposit_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: deposit_amount * pool_info_datum.pool_asset_decimals,
      total_borrowed: 0,
      reserve: 0,
      total_ctoken: deposit_amount,
    }
  let batcher_fee = 300_000
  let order_datum =
    ODeposit {
      o_pool_id: t_pool_id,
      o_owner_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      o_owner_stake_key: Some(
        #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
      ),
      o_amount: deposit_amount,
      o_batcher_fee: batcher_fee,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: t_init_pool_output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            deposit_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              deposit_amount * pool_info_datum.pool_asset_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.ctoken.policy_id,
            pool_info_datum.ctoken.asset_name,
            deposit_amount,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.ctoken.policy_id,
      pool_info_datum.ctoken.asset_name,
      deposit_amount,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyDeposit {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(t_init_pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_deposit_non_ada() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_non_ada()
  let (license_input, license_output) = get_license_input_output()
  let pool_input =
    Input { output_reference: t_pool_outref, output: t_init_pool_output }
  let deposit_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: deposit_amount * pool_info_datum.pool_asset_decimals,
      total_borrowed: 0,
      reserve: 0,
      total_ctoken: deposit_amount,
    }
  let batcher_fee = 300_000
  let order_datum =
    ODeposit {
      o_pool_id: t_pool_id,
      o_owner_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      o_owner_stake_key: Some(
        #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
      ),
      o_amount: deposit_amount,
      o_batcher_fee: batcher_fee,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: t_init_pool_output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            deposit_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              deposit_amount * pool_info_datum.pool_asset_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.ctoken.policy_id,
            pool_info_datum.ctoken.asset_name,
            deposit_amount,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.ctoken.policy_id,
      pool_info_datum.ctoken.asset_name,
      deposit_amount,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyDeposit {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(t_init_pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_deposit_ada_collateral() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_ada_collateral()
  let (license_input, license_output) = get_license_input_output()
  let pool_input =
    Input { output_reference: t_pool_outref, output: t_init_pool_output }
  let deposit_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: deposit_amount * pool_info_datum.pool_asset_decimals,
      total_borrowed: 0,
      reserve: 0,
      total_ctoken: deposit_amount,
    }
  let batcher_fee = 300_000
  let order_datum =
    ODeposit {
      o_pool_id: t_pool_id,
      o_owner_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      o_owner_stake_key: Some(
        #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
      ),
      o_amount: deposit_amount,
      o_batcher_fee: batcher_fee,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: t_init_pool_output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            deposit_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              deposit_amount * pool_info_datum.pool_asset_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.ctoken.policy_id,
            pool_info_datum.ctoken.asset_name,
            deposit_amount,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.ctoken.policy_id,
      pool_info_datum.ctoken.asset_name,
      deposit_amount,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyDeposit {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(t_init_pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_withdraw() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let withdraw_amount = 10
  let withdraw_value =
    withdraw_amount * pool_datum.total_supplied / pool_datum.total_ctoken
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: pool_datum.total_supplied - withdraw_value,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: pool_datum.total_ctoken - withdraw_amount,
    }
  let batcher_fee = 300_000
  let order_datum =
    OWithdraw {
      o_pool_id: t_pool_id,
      o_owner_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      o_owner_stake_key: Some(
        #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
      ),
      o_amount: withdraw_amount,
      o_batcher_fee: batcher_fee,
    }
  let pool_output =
    Output {
      address: pool_input.output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -withdraw_value,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.ctoken.policy_id,
              pool_info_datum.ctoken.asset_name,
              withdraw_amount,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            withdraw_value,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.ctoken.policy_id,
      pool_info_datum.ctoken.asset_name,
      -withdraw_amount,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyWithdraw {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_withdraw_non_ada() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_non_ada()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let withdraw_amount = 10
  let withdraw_value =
    withdraw_amount * pool_datum.total_supplied / pool_datum.total_ctoken
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: pool_datum.total_supplied - withdraw_value,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: pool_datum.total_ctoken - withdraw_amount,
    }
  let batcher_fee = 300_000
  let order_datum =
    OWithdraw {
      o_pool_id: t_pool_id,
      o_owner_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      o_owner_stake_key: Some(
        #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
      ),
      o_amount: withdraw_amount,
      o_batcher_fee: batcher_fee,
    }
  let pool_output =
    Output {
      address: pool_input.output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -withdraw_value,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.ctoken.policy_id,
              pool_info_datum.ctoken.asset_name,
              withdraw_amount,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            withdraw_value,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.ctoken.policy_id,
      pool_info_datum.ctoken.asset_name,
      -withdraw_amount,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyWithdraw {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_withdraw_ada_collateral() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_ada_collateral()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let withdraw_amount = 10
  let withdraw_value =
    withdraw_amount * pool_datum.total_supplied / pool_datum.total_ctoken
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: pool_datum.total_supplied - withdraw_value,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: pool_datum.total_ctoken - withdraw_amount,
    }
  let batcher_fee = 300_000
  let order_datum =
    OWithdraw {
      o_pool_id: t_pool_id,
      o_owner_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      o_owner_stake_key: Some(
        #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
      ),
      o_amount: withdraw_amount,
      o_batcher_fee: batcher_fee,
    }
  let pool_output =
    Output {
      address: pool_input.output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -withdraw_value,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.ctoken.policy_id,
              pool_info_datum.ctoken.asset_name,
              withdraw_amount,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            withdraw_value,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.ctoken.policy_id,
      pool_info_datum.ctoken.asset_name,
      -withdraw_amount,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyWithdraw {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_borrow() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let principal_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: principal_amount * pool_info_datum.pool_asset_decimals,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let collateral_amount = 40
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let order_datum =
    OBorrow {
      o_pool_id: t_pool_id,
      o_owner_pkh: owner_pkh,
      o_owner_stake_key: owner_stake_key,
      o_batcher_fee: batcher_fee,
      o_principal: principal_amount,
      o_collateral_amount: collateral_amount,
      o_collateral_asset: t_collateral_asset,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount * 2 + batcher_fee,
        )
          |> assets.add(
              t_collateral_asset.policy_id,
              t_collateral_asset.asset_name,
              collateral_amount * t_collateral_info.collateral_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, vault_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyBorrow {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_borrow_non_ada() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_non_ada()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let principal_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: principal_amount * pool_info_datum.pool_asset_decimals,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let collateral_amount = 40
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let order_datum =
    OBorrow {
      o_pool_id: t_pool_id,
      o_owner_pkh: owner_pkh,
      o_owner_stake_key: owner_stake_key,
      o_batcher_fee: batcher_fee,
      o_principal: principal_amount,
      o_collateral_amount: collateral_amount,
      o_collateral_asset: t_collateral_asset,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount * 2 + batcher_fee,
        )
          |> assets.add(
              t_collateral_asset.policy_id,
              t_collateral_asset.asset_name,
              collateral_amount * t_collateral_info.collateral_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, vault_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyBorrow {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_borrow_ada_collateral() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_ada_collateral()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 0,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info_ada.oracle_nft.policy_id,
              t_collateral_info_ada.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let principal_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: principal_amount * pool_info_datum.pool_asset_decimals,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let collateral_amount = 40
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let order_datum =
    OBorrow {
      o_pool_id: t_pool_id,
      o_owner_pkh: owner_pkh,
      o_owner_stake_key: owner_stake_key,
      o_batcher_fee: batcher_fee,
      o_principal: principal_amount,
      o_collateral_amount: collateral_amount,
      o_collateral_asset: t_collateral_asset_ada,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount * 2 + batcher_fee,
        )
          |> assets.add(
              t_collateral_asset_ada.policy_id,
              t_collateral_asset_ada.asset_name,
              collateral_amount * t_collateral_info.collateral_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset_ada,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset_ada.policy_id,
            t_collateral_asset_ada.asset_name,
            collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, vault_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyBorrow {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_borrow_init_total_borrowed_not_null() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 10_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let principal_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: pool_datum.total_borrowed + principal_amount * pool_info_datum.pool_asset_decimals,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let collateral_amount = 40
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let order_datum =
    OBorrow {
      o_pool_id: t_pool_id,
      o_owner_pkh: owner_pkh,
      o_owner_stake_key: owner_stake_key,
      o_batcher_fee: batcher_fee,
      o_principal: principal_amount,
      o_collateral_amount: collateral_amount,
      o_collateral_asset: t_collateral_asset,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount * 2 + batcher_fee,
        )
          |> assets.add(
              t_collateral_asset.policy_id,
              t_collateral_asset.asset_name,
              collateral_amount * t_collateral_info.collateral_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, vault_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyBorrow {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_borrow_init_total_borrowed_not_null_non_ada() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_non_ada()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 10_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let principal_amount = 10
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: pool_datum.total_borrowed + principal_amount * pool_info_datum.pool_asset_decimals,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let collateral_amount = 40
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let order_datum =
    OBorrow {
      o_pool_id: t_pool_id,
      o_owner_pkh: owner_pkh,
      o_owner_stake_key: owner_stake_key,
      o_batcher_fee: batcher_fee,
      o_principal: principal_amount,
      o_collateral_amount: collateral_amount,
      o_collateral_asset: t_collateral_asset,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            -principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount * 2 + batcher_fee,
        )
          |> assets.add(
              t_collateral_asset.policy_id,
              t_collateral_asset.asset_name,
              collateral_amount * t_collateral_info.collateral_decimals,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            principal_amount * pool_info_datum.pool_asset_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, vault_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727456400000),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyBorrow {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 2,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_repay() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let borrow_id =
    OutputReference {
      transaction_id: #"07f157faf99b850b4971034feee28d",
      output_index: 0,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id,
      owner_pkh,
      owner_stake_key,
      collateral_amount: 40,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: 10,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let end_valid_time_range = vault_datum.start_time + 180 * 24 * 60 * 60 * 1000
  let payment =
    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
      multiplier + vault_datum.interest_rate * (
        end_valid_time_range - vault_datum.start_time
      ) / year_in_seconds
    ) / multiplier
  let profit =
    payment - vault_datum.principal * pool_info_datum.pool_asset_decimals
  let add_to_reserve =
    profit * pool_info_datum.reserve_factor_percentage / multiplier
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000 + ( profit - add_to_reserve ),
      total_borrowed: pool_datum.total_borrowed - vault_datum.principal * pool_info_datum.pool_asset_decimals,
      reserve: pool_datum.reserve + add_to_reserve,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let order_datum =
    ORepay {
      o_pool_id: t_pool_id,
      o_batcher_fee: batcher_fee,
      o_borrow_id: borrow_id,
      o_owner_pkh: owner_pkh,
      o_time: end_valid_time_range,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            payment,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              payment,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            vault_datum.collateral_asset.policy_id,
            vault_datum.collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      -1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, vault_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(end_valid_time_range),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyRepay {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 3,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_repay_non_ada() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_non_ada()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let borrow_id =
    OutputReference {
      transaction_id: #"07f157faf99b850b4971034feee28d",
      output_index: 0,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id,
      owner_pkh,
      owner_stake_key,
      collateral_amount: 40,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: 10,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let end_valid_time_range = vault_datum.start_time + 180 * 24 * 60 * 60 * 1000
  let payment =
    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
      multiplier + vault_datum.interest_rate * (
        end_valid_time_range - vault_datum.start_time
      ) / year_in_seconds
    ) / multiplier
  let profit =
    payment - vault_datum.principal * pool_info_datum.pool_asset_decimals
  let add_to_reserve =
    profit * pool_info_datum.reserve_factor_percentage / multiplier
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000 + ( profit - add_to_reserve ),
      total_borrowed: pool_datum.total_borrowed - vault_datum.principal * pool_info_datum.pool_asset_decimals,
      reserve: pool_datum.reserve + add_to_reserve,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let order_datum =
    ORepay {
      o_pool_id: t_pool_id,
      o_batcher_fee: batcher_fee,
      o_borrow_id: borrow_id,
      o_owner_pkh: owner_pkh,
      o_time: end_valid_time_range,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            payment,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              payment,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            vault_datum.collateral_asset.policy_id,
            vault_datum.collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      -1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, vault_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(end_valid_time_range),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyRepay {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 3,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_repay_ada_collateral() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_ada_collateral()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 500_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info_ada.oracle_nft.policy_id,
              t_collateral_info_ada.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let borrow_id =
    OutputReference {
      transaction_id: #"07f157faf99b850b4971034feee28d",
      output_index: 0,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id,
      owner_pkh,
      owner_stake_key,
      collateral_amount: 40,
      collateral_asset: t_collateral_asset_ada,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: 10,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            vault_datum.collateral_asset.policy_id,
            vault_datum.collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let end_valid_time_range = vault_datum.start_time + 180 * 24 * 60 * 60 * 1000
  let payment =
    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
      multiplier + vault_datum.interest_rate * (
        end_valid_time_range - vault_datum.start_time
      ) / year_in_seconds
    ) / multiplier
  let profit =
    payment - vault_datum.principal * pool_info_datum.pool_asset_decimals
  let add_to_reserve =
    profit * pool_info_datum.reserve_factor_percentage / multiplier
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000 + ( profit - add_to_reserve ),
      total_borrowed: pool_datum.total_borrowed - vault_datum.principal * pool_info_datum.pool_asset_decimals,
      reserve: pool_datum.reserve + add_to_reserve,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let order_datum =
    ORepay {
      o_pool_id: t_pool_id,
      o_batcher_fee: batcher_fee,
      o_borrow_id: borrow_id,
      o_owner_pkh: owner_pkh,
      o_time: end_valid_time_range,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            payment,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              payment,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let user_address =
    address.from_verification_key(
      #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
    )
      |> address.with_delegation_key(
          #"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3",
        )
  let user_out =
    Output {
      address: user_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            vault_datum.collateral_asset.policy_id,
            vault_datum.collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          ),
      datum: NoDatum,
      reference_script: None,
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      -1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, vault_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, user_out, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(end_valid_time_range),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyRepay {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 3,
      order_indices: [(1, 1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_liquidate() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 100_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let borrow_id =
    OutputReference {
      transaction_id: #"07f157faf99b850b4971034feee28d",
      output_index: 0,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id,
      owner_pkh,
      owner_stake_key,
      collateral_amount: 40,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: 10,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let end_valid_time_range = vault_datum.start_time + 180 * 24 * 60 * 60 * 1000
  let payment =
    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
      multiplier + vault_datum.interest_rate * (
        end_valid_time_range - vault_datum.start_time
      ) / year_in_seconds
    ) / multiplier
  let profit =
    payment - vault_datum.principal * pool_info_datum.pool_asset_decimals
  let add_to_reserve =
    profit * pool_info_datum.reserve_factor_percentage / multiplier
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000 + ( profit - add_to_reserve ),
      total_borrowed: pool_datum.total_borrowed - vault_datum.principal * pool_info_datum.pool_asset_decimals,
      reserve: pool_datum.reserve + add_to_reserve,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let order_datum =
    OLiquidate {
      o_pool_id: t_pool_id,
      o_batcher_fee: batcher_fee,
      o_borrow_id: borrow_id,
      o_owner_pkh: owner_pkh,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            payment,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              payment,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      -1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, vault_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(end_valid_time_range),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyLiquidate {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 3,
      order_indices: [(1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_liquidate_non_ada() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_non_ada()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 100_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info.oracle_nft.policy_id,
              t_collateral_info.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let borrow_id =
    OutputReference {
      transaction_id: #"07f157faf99b850b4971034feee28d",
      output_index: 0,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id,
      owner_pkh,
      owner_stake_key,
      collateral_amount: 40,
      collateral_asset: t_collateral_asset,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: 10,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let end_valid_time_range = vault_datum.start_time + 180 * 24 * 60 * 60 * 1000
  let payment =
    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
      multiplier + vault_datum.interest_rate * (
        end_valid_time_range - vault_datum.start_time
      ) / year_in_seconds
    ) / multiplier
  let profit =
    payment - vault_datum.principal * pool_info_datum.pool_asset_decimals
  let add_to_reserve =
    profit * pool_info_datum.reserve_factor_percentage / multiplier
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000 + ( profit - add_to_reserve ),
      total_borrowed: pool_datum.total_borrowed - vault_datum.principal * pool_info_datum.pool_asset_decimals,
      reserve: pool_datum.reserve + add_to_reserve,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let order_datum =
    OLiquidate {
      o_pool_id: t_pool_id,
      o_batcher_fee: batcher_fee,
      o_borrow_id: borrow_id,
      o_owner_pkh: owner_pkh,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            payment,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              payment,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      -1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, vault_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(end_valid_time_range),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyLiquidate {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 3,
      order_indices: [(1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_liquidate_ada_collateral() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info_ada_collateral()
  let (license_input, license_output) = get_license_input_output()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let oracle_datum = OracleDatum { price: 100_000, updated_at: 1727453227635 }
  let oracle_ref =
    OutputReference {
      transaction_id: #"f99b85b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let oracle_input =
    Input {
      output_reference: oracle_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.zero
          |> assets.add(
              t_collateral_info_ada.oracle_nft.policy_id,
              t_collateral_info_ada.oracle_nft.asset_name,
              1,
            ),
        datum: InlineDatum(oracle_datum),
        reference_script: None,
      },
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let borrow_id =
    OutputReference {
      transaction_id: #"07f157faf99b850b4971034feee28d",
      output_index: 0,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let u = pool_datum.total_borrowed * multiplier / pool_datum.total_supplied
  let interest_rate = cal_interest_rate(u, pool_info_datum)
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id,
      owner_pkh,
      owner_stake_key,
      collateral_amount: 40,
      collateral_asset: t_collateral_asset_ada,
      collateral_decimals: t_collateral_info.collateral_decimals,
      interest_rate,
      start_time: 1727453227635,
      principal: 10,
    }
  let vault_address =
    when pool_info_datum.pool_stake_key is {
      Some(key) ->
        address.from_script(pool_info_datum.vault_script_hash)
          |> address.with_delegation_script(key)
      None -> address.from_script(pool_info_datum.vault_script_hash)
    }
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset_ada.policy_id,
            t_collateral_asset_ada.asset_name,
            vault_datum.collateral_amount * t_collateral_info.collateral_decimals,
          )
        |> assets.add(
            pool_info_datum.vault_authtoken.policy_id,
            pool_info_datum.vault_authtoken.asset_name,
            1,
          ),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let end_valid_time_range = vault_datum.start_time + 180 * 24 * 60 * 60 * 1000
  let payment =
    vault_datum.principal * pool_info_datum.pool_asset_decimals * (
      multiplier + vault_datum.interest_rate * (
        end_valid_time_range - vault_datum.start_time
      ) / year_in_seconds
    ) / multiplier
  let profit =
    payment - vault_datum.principal * pool_info_datum.pool_asset_decimals
  let add_to_reserve =
    profit * pool_info_datum.reserve_factor_percentage / multiplier
  let pool_out_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000 + ( profit - add_to_reserve ),
      total_borrowed: pool_datum.total_borrowed - vault_datum.principal * pool_info_datum.pool_asset_decimals,
      reserve: pool_datum.reserve + add_to_reserve,
      total_ctoken: 50,
    }
  let batcher_fee = 300_000
  let order_datum =
    OLiquidate {
      o_pool_id: t_pool_id,
      o_batcher_fee: batcher_fee,
      o_borrow_id: borrow_id,
      o_owner_pkh: owner_pkh,
    }
  let pool_output =
    Output {
      address: t_init_pool_output.address,
      value: pool_input.output.value
        |> assets.add(
            pool_info_datum.pool_asset.policy_id,
            pool_info_datum.pool_asset.asset_name,
            payment,
          ),
      datum: InlineDatum(pool_out_datum),
      reference_script: None,
    }
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let order_input =
    Input {
      output_reference: order_ref,
      output: Output {
        address: from_script(#"11"),
        value: assets.from_lovelace(
          pool_info_datum.envelope_amount + batcher_fee,
        )
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              payment,
            ),
        datum: InlineDatum(order_datum),
        reference_script: None,
      },
    }
  let mint =
    assets.from_asset(
      pool_info_datum.vault_authtoken.policy_id,
      pool_info_datum.vault_authtoken.asset_name,
      -1,
    )
  let tx =
    Transaction {
      inputs: [pool_input, order_input, vault_input, license_input],
      reference_inputs: [pool_info_input, oracle_input],
      outputs: [pool_output, license_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(end_valid_time_range),
          is_inclusive: False,
        },
      },
      extra_signatories: [],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer =
    ApplyLiquidate {
      own_input_idx: 0,
      own_output_idx: 0,
      pool_info_idx: 0,
      license_idx: 3,
      order_indices: [(1, 2, 1)],
    }
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}

test pool_spend_apply_close() {
  let (_pool_info_input, pool_info_datum) = test_get_pool_info()
  let pool_datum =
    PoolDatum {
      pool_id: t_pool_id,
      total_supplied: 60_000_000,
      total_borrowed: 20_000_000,
      reserve: 1_000_000,
      total_ctoken: 50,
    }
  let pool_input =
    Input {
      output_reference: t_pool_outref,
      output: Output {
        address: from_script(t_pool_script_hash)
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(2_000_000)
          |> assets.add(t_pool_authtoken_policy_id, pool_nft_tn, 1)
          |> assets.add(
              pool_info_datum.pool_asset.policy_id,
              pool_info_datum.pool_asset.asset_name,
              pool_datum.total_supplied,
            ),
        datum: InlineDatum(pool_datum),
        reference_script: None,
      },
    }
  let tx =
    Transaction {
      inputs: [pool_input],
      reference_inputs: [],
      outputs: [],
      fee: 0,
      mint: assets.zero,
      certificates: [],
      withdrawals: [],
      validity_range: Interval {
        lower_bound: IntervalBound {
          bound_type: Finite(1727453227635),
          is_inclusive: False,
        },
        upper_bound: IntervalBound {
          bound_type: Finite(1727455227635),
          is_inclusive: False,
        },
      },
      extra_signatories: [t_admin_pkh],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let pool_redeemer = Close
  let params =
    PoolParams {
      admin_pkh: t_admin_pkh,
      pool_nft: t_pool_nft,
      pool_info_nft: t_pool_info_nft,
    }
  pool.spend(params, Some(pool_datum), pool_redeemer, t_pool_outref, tx)
}
