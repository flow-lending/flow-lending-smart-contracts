// Mint/burn authorization token for vault UTxO to apply borrow, repay, or liquidate actions.
// Delegates logic to the pool validator.
//
// This validator is parameterized by the pool id and pool NFT for a specific pool.
//
// Redeemer actions and their validation logic:
//
// VaultAuthTokenRedeemer:
//   - pool_in_idx: Int
//       * Specifies the index of the pool input in the transaction inputs.
//       * Used to reference the correct pool UTxO for validation.
//
// Validation checks performed by the vault_authtoken validator:
//   - Ensures the referenced pool input exists at the given index.
//   - Ensures the pool input contains a valid inline datum of type PoolDatum.
//   - Ensures the pool_id in the datum matches the expected pool_id in parameters.
//   - Ensures the correct PoolRedeemer is present for the referenced pool input.
//   - Ensures the pool NFT is present in the pool input value.
//   - Only allows minting/burning vault auth tokens if the pool redeemer is one of:
//       * ApplyBorrow: Validates minting/burning for a borrow action.
//       * ApplyRepay: Validates minting/burning for a repay action.
//       * ApplyLiquidate: Validates minting/burning for a liquidation action.
//       * Close: Allows burning when closing the pool.
//   - Any other redeemer action is rejected.

use aiken/collection/list
use aiken/collection/pairs
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, OutputReference, Spend, Transaction}
use pool.{AdminOperation, ApplyBorrow, ApplyLiquidate, ApplyRepay, PoolRedeemer}
use types.{Asset, PoolDatum}

pub type VaultAuthTokenRedeemer {
  pool_in_idx: Int,
}

pub type VaultAuthTokenParams {
  pool_id: OutputReference,
  pool_nft: Asset,
}

validator vault_authtoken(params: VaultAuthTokenParams) {
  mint(
    redeemer: VaultAuthTokenRedeemer,
    _policy_id: PolicyId,
    self: Transaction,
  ) {
    let Transaction { inputs, redeemers, .. } = self
    expect Some(pool_input) = list.at(inputs, redeemer.pool_in_idx)
    expect InlineDatum(pool_inline_datum) = pool_input.output.datum
    expect pool_datum: PoolDatum = pool_inline_datum
    expect pool_datum.pool_id == params.pool_id
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
      ApplyBorrow { .. } -> True
      ApplyRepay { .. } -> True
      ApplyLiquidate { .. } -> True
      AdminOperation -> True
      _ -> False
    }
  }

  else(_) {
    fail
  }
}
