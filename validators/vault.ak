// Validator controls collateral for borrowing. Vault UTxO can be spent to apply repay or liquidate actions, or to add collateral to the vault.
//
// This validator is parameterized by admin public key hash, pool id, and pool NFT.
//
// Redeemer actions and their validation logic:
//
// VaultRedeemer:
//   - VSpend { pool_in_idx: Int }
//       * Spends the vault UTxO in response to a pool action (repay, liquidate, or close).
//       * Checks:
//           - The referenced pool input exists at pool_in_idx in transaction inputs.
//           - The pool input contains a valid PoolDatum inline datum.
//           - The pool_id in the datum matches the expected pool_id in parameters.
//           - The correct PoolRedeemer is present for the referenced pool input.
//           - The pool NFT is present in the pool input value.
//           - Only allows spending if the pool redeemer is one of:
//               * ApplyRepay: Repayment of a loan.
//               * ApplyLiquidate: Liquidation of collateral.
//               * Close: Pool closure.
//           - Any other redeemer action is rejected.
//
//   - VAddCollateral { own_input_idx: Int, own_output_idx: Int, add_amount: Int }
//       * Adds collateral to the vault.
//       * Checks:
//           - The referenced own input and output exist at the given indices.
//           - The input and output refer to the same vault (output_reference matches own_outref).
//           - The output contains a valid VaultDatum inline datum.
//           - All fields in the datum remain unchanged except for collateral_amount, which increases by add_amount.
//           - The output value matches the expected value after adding the collateral.
//           - The transaction is signed by the vault owner (owner_pkh).
//
//   - VSlash
//       * Allows the admin to slash (seize) the vault collateral.
//       * Checks:
//           - The transaction is signed by the admin (params.admin_pkh).
//
// ## Transaction Flows & Action Examples
//
// ### 1. Add Collateral to Vault
//
// **Purpose:**
// - The vault owner increases the collateral in their vault.
//
// **Inputs:**
// - Vault UTxO (with current collateral and VaultDatum).
//
// **Outputs:**
// - New vault UTxO (with increased collateral and updated VaultDatum).
//
// **Reference Inputs:**
// - None required.
//
// **Redeemer:**
// - `VAddCollateral { own_input_idx, own_output_idx, add_amount }`
//
// **Checks:**
// - The input and output refer to the same vault (output_reference matches own_outref).
// - All fields in the datum remain unchanged except `collateral_amount`, which increases by `add_amount`.
// - The output value matches the expected value after adding collateral.
// - The transaction is signed by the vault owner.
//
// **Example:**
// - Vault UTxO with 1,000 collateral.
// - Owner adds 100 collateral.
// - Output vault UTxO has 1,100 collateral.
// - Redeemer: `VAddCollateral { own_input_idx: 0, own_output_idx: 0, add_amount: 100 }`
//
// ---
//
// ### 2. Repay or Liquidate Vault
//
// **Purpose:**
// - The vault UTxO is spent as part of a pool action (repay, liquidate, or close).
//
// **Inputs:**
// - Vault UTxO (with VaultDatum).
// - Pool UTxO (with PoolDatum).
//
// **Outputs:**
// - As required by the pool operation (e.g., vault closed, collateral released or seized).
//
// **Reference Inputs:**
// - None required.
//
// **Redeemer:**
// - `VSpend { pool_in_idx }`
//
// **Checks:**
// - The referenced pool input exists and contains a valid PoolDatum.
// - The pool_id matches.
// - The correct PoolRedeemer is present (must be `ApplyRepay`, `ApplyLiquidate`, or `Close`).
// - The pool NFT is present in the pool input value.
//
// **Example:**
// - Vault is being repaid or liquidated as part of a pool operation.
// - Redeemer: `VSpend { pool_in_idx: 1 }`
//
// ---
//
// ### 3. Slash Vault
//
// **Purpose:**
// - The admin seizes (slashes) the vault collateral.
//
// **Inputs:**
// - Vault UTxO (with VaultDatum).
//
// **Outputs:**
// - As required by the slashing logic (e.g., collateral moved to admin or protocol address).
//
// **Reference Inputs:**
// - None required.
//
// **Redeemer:**
// - `VSlash`
//
// **Checks:**
// - The transaction is signed by the admin (params.admin_pkh).
//
// **Example:**
// - Admin slashes a vault due to protocol violation.
// - Redeemer: `VSlash`

//
use aiken/collection/dict
use aiken/collection/list
use aiken/collection/pairs
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Spend, Transaction,
}
use pool.{AdminOperation, ApplyLiquidate, ApplyRepay, PoolRedeemer}
use test_constants.{
  t_collateral_asset, t_collateral_asset_ada, t_pool_id, t_pool_nft,
  t_vault_authtoken,
}
use types.{Asset, PoolDatum, VaultDatum}

pub type VaultRedeemer {
  VSpend { pool_in_idx: Int }
  VAddCollateral { own_input_idx: Int, own_output_idx: Int, add_amount: Int }
  VSlash
}

pub type VaultParams {
  admin_pkh: ByteArray,
  pool_id: OutputReference,
  pool_nft: Asset,
}

validator vault(params: VaultParams) {
  spend(
    option_datum: Option<VaultDatum>,
    redeemer: VaultRedeemer,
    own_outref: OutputReference,
    self: Transaction,
  ) {
    let Transaction { inputs, outputs, extra_signatories, redeemers, .. } = self
    when redeemer is {
      VSpend { pool_in_idx } -> {
        expect Some(pool_input) = list.at(inputs, pool_in_idx)
        expect InlineDatum(pool_inline_datum) = pool_input.output.datum
        expect pool_datum: PoolDatum = pool_inline_datum
        expect params.pool_id == pool_datum.pool_id
        expect Some(wrap_pool_redeemer) =
          pairs.get_first(redeemers, Spend(pool_input.output_reference))
        expect pool_redeemer: PoolRedeemer = wrap_pool_redeemer
        expect
          assets.quantity_of(
            pool_input.output.value,
            params.pool_nft.policy_id,
            params.pool_nft.asset_name,
          ) == 1
        when pool_redeemer is {
          ApplyRepay { .. } -> True
          ApplyLiquidate { .. } -> True
          AdminOperation -> True
          _ -> False
        }
      }
      VAddCollateral { own_input_idx, own_output_idx, add_amount } -> {
        expect Some(datum) = option_datum
        let own_input_datum: VaultDatum = datum
        expect Some(own_input) = list.at(inputs, own_input_idx)
        expect Some(own_output) = list.at(outputs, own_output_idx)
        expect own_input.output.address == own_output.address
        expect own_input.output_reference == own_outref
        expect InlineDatum(own_output_inline_datum) = own_output.datum
        expect own_output_datum: VaultDatum = own_output_inline_datum
        expect own_input_datum.pool_id == own_output_datum.pool_id
        expect own_input_datum.pool_id == params.pool_id
        expect own_input_datum.borrow_id == own_output_datum.borrow_id
        expect own_input_datum.owner_pkh == own_output_datum.owner_pkh
        expect
          own_input_datum.owner_stake_key == own_output_datum.owner_stake_key
        expect
          own_input_datum.collateral_asset == own_output_datum.collateral_asset
        expect own_input_datum.interest_rate == own_output_datum.interest_rate
        expect own_input_datum.principal == own_output_datum.principal
        expect own_input_datum.start_time == own_output_datum.start_time
        expect
          own_input_datum.collateral_amount + add_amount == own_output_datum.collateral_amount
        expect add_amount > 0
        let expected_output_value =
          assets.add(
            own_input.output.value,
            own_input_datum.collateral_asset.policy_id,
            own_input_datum.collateral_asset.asset_name,
            add_amount,
          )
        expect assets.match(own_output.value, expected_output_value, >=)
        list.has(extra_signatories, own_input_datum.owner_pkh)
      }

      VSlash -> list.has(extra_signatories, params.admin_pkh)
    }
  }

  else(_) {
    fail
  }
}

test assets_match() {
  let in_value =
    assets.from_lovelace(30)
      |> assets.add(
          t_vault_authtoken.policy_id,
          t_vault_authtoken.asset_name,
          1,
        )
      |> assets.add(
          t_collateral_asset.policy_id,
          t_collateral_asset.asset_name,
          42,
        )

  let out_value =
    assets.from_lovelace(40)
      |> assets.add(
          t_vault_authtoken.policy_id,
          t_vault_authtoken.asset_name,
          1,
        )
      |> assets.add(
          t_collateral_asset.policy_id,
          t_collateral_asset.asset_name,
          42,
        )
      |> assets.add(
          t_collateral_asset.policy_id,
          t_collateral_asset.asset_name,
          10,
        )
  let expected_output_value =
    in_value
      |> assets.add(
          t_collateral_asset.policy_id,
          t_collateral_asset.asset_name,
          10,
        )

  True == assets.match(out_value, expected_output_value, >=)
}

test vault_spend_add_collateral() {
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let collateral_amount = 1000
  let interest_rate = 1000
  let principal_amount = 100
  let add_amount = 100
  let vault_authtoken_policy_id =
    "a0e8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49"
  let vault_authtoken_asset_name =
    "a0e8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49"
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let vault_address =
    address.from_script(
      #"e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49",
    )
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount,
          )
        |> assets.add(vault_authtoken_policy_id, vault_authtoken_asset_name, 1),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let output_vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount: collateral_amount + add_amount,
      collateral_asset: t_collateral_asset,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let output_vault =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount + add_amount,
          )
        |> assets.add(vault_authtoken_policy_id, vault_authtoken_asset_name, 1),
      datum: InlineDatum(output_vault_datum),
      reference_script: None,
    }
  let tx =
    Transaction {
      inputs: [vault_input],
      reference_inputs: [],
      outputs: [output_vault],
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
          bound_type: Finite(1737453227635),
          is_inclusive: False,
        },
      },
      extra_signatories: [vault_datum.owner_pkh],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let vault_redeemer =
    VAddCollateral { own_input_idx: 0, own_output_idx: 0, add_amount }
  let vault_params =
    VaultParams {
      admin_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      pool_id: t_pool_id,
      pool_nft: t_pool_nft,
    }
  vault.spend(vault_params, Some(vault_datum), vault_redeemer, vault_outref, tx)
}

test vault_spend_add_collateral_fail() fail {
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let collateral_amount = 1000
  let interest_rate = 1000
  let principal_amount = 100
  let add_amount = -10
  let vault_authtoken_policy_id =
    "a0e8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49"
  let vault_authtoken_asset_name =
    "a0e8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49"
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let vault_address =
    address.from_script(
      #"e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49",
    )
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount,
          )
        |> assets.add(vault_authtoken_policy_id, vault_authtoken_asset_name, 1),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let output_vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount: collateral_amount + add_amount,
      collateral_asset: t_collateral_asset,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let output_vault =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset.policy_id,
            t_collateral_asset.asset_name,
            vault_datum.collateral_amount + add_amount,
          )
        |> assets.add(vault_authtoken_policy_id, vault_authtoken_asset_name, 1),
      datum: InlineDatum(output_vault_datum),
      reference_script: None,
    }
  let tx =
    Transaction {
      inputs: [vault_input],
      reference_inputs: [],
      outputs: [output_vault],
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
          bound_type: Finite(1737453227635),
          is_inclusive: False,
        },
      },
      extra_signatories: [vault_datum.owner_pkh],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let vault_redeemer =
    VAddCollateral { own_input_idx: 0, own_output_idx: 0, add_amount }
  let vault_params =
    VaultParams {
      admin_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      pool_id: t_pool_id,
      pool_nft: t_pool_nft,
    }
  vault.spend(vault_params, Some(vault_datum), vault_redeemer, vault_outref, tx)
}

test vault_spend_add_collateral_ada() {
  let order_ref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 0,
    }
  let owner_pkh = #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b"
  let owner_stake_key =
    Some(#"c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3")
  let collateral_amount = 1000
  let interest_rate = 1000
  let principal_amount = 100
  let add_amount = 100
  let vault_authtoken_policy_id =
    "a0e8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49"
  let vault_authtoken_asset_name =
    "a0e8c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49"
  let vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount,
      collateral_asset: t_collateral_asset_ada,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let vault_outref =
    OutputReference {
      transaction_id: #"b4971034feee28d07f157faf99b850",
      output_index: 1,
    }
  let vault_address =
    address.from_script(
      #"e6648c7cffe3c8f2b6b7d779788f50f4c9f9c4252d86702c2f4c2e49",
    )
  let vault_out =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset_ada.policy_id,
            t_collateral_asset_ada.asset_name,
            vault_datum.collateral_amount,
          )
        |> assets.add(vault_authtoken_policy_id, vault_authtoken_asset_name, 1),
      datum: InlineDatum(vault_datum),
      reference_script: None,
    }
  let vault_input = Input { output_reference: vault_outref, output: vault_out }
  let output_vault_datum =
    VaultDatum {
      pool_id: t_pool_id,
      borrow_id: order_ref,
      owner_pkh,
      owner_stake_key,
      collateral_amount: collateral_amount + add_amount,
      collateral_asset: t_collateral_asset_ada,
      interest_rate,
      start_time: 1727453227635,
      principal: principal_amount,
    }
  let output_vault =
    Output {
      address: vault_address,
      value: assets.from_lovelace(2_000_000)
        |> assets.add(
            t_collateral_asset_ada.policy_id,
            t_collateral_asset_ada.asset_name,
            vault_datum.collateral_amount + add_amount,
          )
        |> assets.add(vault_authtoken_policy_id, vault_authtoken_asset_name, 1),
      datum: InlineDatum(output_vault_datum),
      reference_script: None,
    }
  let tx =
    Transaction {
      inputs: [vault_input],
      reference_inputs: [],
      outputs: [output_vault],
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
          bound_type: Finite(1737453227635),
          is_inclusive: False,
        },
      },
      extra_signatories: [vault_datum.owner_pkh],
      redeemers: [],
      datums: dict.empty,
      id: #"0000000000000000000000000000000000000000000000000000000000000000",
      votes: [],
      proposal_procedures: [],
      current_treasury_amount: None,
      treasury_donation: None,
    }
  let vault_redeemer =
    VAddCollateral { own_input_idx: 0, own_output_idx: 0, add_amount }
  let vault_params =
    VaultParams {
      admin_pkh: #"6b7d779788f50f4c9f9c4252d86702c2f4c2e49e6648c7cffe3c8f2b",
      pool_id: t_pool_id,
      pool_nft: t_pool_nft,
    }
  vault.spend(vault_params, Some(vault_datum), vault_redeemer, vault_outref, tx)
}
