use aiken/collection/dict
use aiken/collection/list
use aiken/interval
use cardano/address.{from_verification_key}
use cardano/assets.{PolicyId, flatten}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use constants.{pool_info_nft_tn, pool_nft_tn}
use test_constants.{
  t_admin_pkh, t_init_pool_output, t_pool_authtoken_policy_id, t_pool_id,
  t_pool_info_output,
}
use types.{PoolDatum, PoolInfoDatum}

pub type MintRedeemer {
  Mint { pool_info_out_idx: Int, pool_out_idx: Int }
  Burn
}

fn is_pool_info_datum_valid(pool_info_datum: PoolInfoDatum) -> Bool {
  expect pool_info_datum.envelope_amount > 0
  expect pool_info_datum.pool_asset_decimals > 0
  expect pool_info_datum.reserve_factor_percentage > 0
  expect pool_info_datum.kink > 0
  expect pool_info_datum.base_rate > 0
  expect pool_info_datum.slope_low > 0
  expect pool_info_datum.slope_high > 0
  list.foldl(
    pool_info_datum.collateral_infos,
    True,
    fn(collateral_info, acc) {
      expect collateral_info.liquidation_threshold > 0
      expect collateral_info.max_borrow_ltv > 0
      expect collateral_info.collateral_decimals > 0
      acc
    },
  )
}

fn is_pool_datum_valid(pool_datum: PoolDatum) -> Bool {
  expect pool_datum.total_supplied == 0
  expect pool_datum.total_borrowed == 0
  expect pool_datum.reserve == 0
  expect pool_datum.total_ctoken == 0
  True
}

pub type PoolAuthTokenParams {
  pool_id: OutputReference,
  admin_pkh: ByteArray,
}

validator pool_auth_token(params: PoolAuthTokenParams) {
  mint(redeemer: MintRedeemer, policy_id: PolicyId, self: Transaction) {
    let Transaction { outputs, mint, extra_signatories, .. } = self
    when redeemer is {
      Mint { pool_info_out_idx, pool_out_idx } -> {
        expect list.has(extra_signatories, params.admin_pkh)
        let pool_info_nft = assets.from_asset(policy_id, pool_info_nft_tn, 1)
        let pool_nft = assets.from_asset(policy_id, pool_nft_tn, 1)
        let merged_mint = assets.merge(pool_info_nft, pool_nft)
        expect Some(pool_info_output) = list.at(outputs, pool_info_out_idx)
        expect Some(pool_output) = list.at(outputs, pool_out_idx)
        expect
          assets.quantity_of(
            pool_info_output.value,
            policy_id,
            pool_info_nft_tn,
          ) == 1
        expect
          assets.quantity_of(pool_output.value, policy_id, pool_nft_tn) == 1
        expect list.length(flatten(pool_info_output.value)) == 2
        expect list.length(flatten(pool_output.value)) == 2
        expect InlineDatum(pool_info_inline_datum) = pool_info_output.datum
        expect pool_info_datum: PoolInfoDatum = pool_info_inline_datum
        expect is_pool_info_datum_valid(pool_info_datum)
        expect InlineDatum(pool_inline_datum) = pool_output.datum
        expect pool_datum: PoolDatum = pool_inline_datum
        expect is_pool_datum_valid(pool_datum)
        expect merged_mint == mint
        True
      }
      Burn -> list.has(extra_signatories, params.admin_pkh)
    }
  }

  else(_) {
    fail
  }
}

test pool_auth_token_mint() {
  let seed_input =
    Input {
      output_reference: t_pool_id,
      output: Output {
        address: from_verification_key(
          #"2d86702c2f4c2e49e6648c7cffe3c8f2b6b7d779788f50f4c9f9c425",
        )
          |> address.with_delegation_script(
              #"2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f",
            ),
        value: assets.from_lovelace(5_000_000),
        datum: NoDatum,
        reference_script: None,
      },
    }
  let own_policy_id = t_pool_authtoken_policy_id
  let mint =
    assets.from_asset(own_policy_id, pool_info_nft_tn, 1)
      |> assets.add(own_policy_id, pool_nft_tn, 1)
  let tx =
    Transaction {
      inputs: [seed_input],
      reference_inputs: [],
      outputs: [t_pool_info_output, t_init_pool_output],
      fee: 0,
      mint,
      certificates: [],
      withdrawals: [],
      validity_range: interval.everything,
      extra_signatories: [t_admin_pkh],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let redeemer = Mint { pool_info_out_idx: 0, pool_out_idx: 1 }
  let params =
    PoolAuthTokenParams { pool_id: t_pool_id, admin_pkh: t_admin_pkh }
  pool_auth_token.mint(params, redeemer, own_policy_id, tx)
}
