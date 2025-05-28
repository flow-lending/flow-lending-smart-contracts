// Validator to mint or burn liquidity provider (cToken) tokens.
//
// This validator delegates logic to the pool validator when spending the pool UTxO to apply deposit or withdraw actions.
//
// Redeemer actions and their validation logic:
//
// CTokenRedeemer:
//   - pool_in_idx: Int
//       * Specifies the index of the pool input in the transaction inputs.
//       * Used to reference the correct pool UTxO for validation.
//
// Validation checks performed by the ctoken validator:
//   - Ensures the referenced pool input exists at the given index.
//   - Ensures the pool input contains a valid inline datum of type PoolDatum.
//   - Ensures the pool_id in the datum matches the expected pool_id in parameters.
//   - Ensures the correct PoolRedeemer is present for the referenced pool input.
//   - Ensures the pool NFT is present in the pool input value.
//   - Only allows minting/burning cTokens if the pool redeemer is one of:
//       * ApplyDeposit: Validates minting cTokens for a deposit action.
//       * ApplyWithdraw: Validates burning cTokens for a withdraw action.
//       * Close: Allows burning cTokens when closing the pool.
//   - Any other redeemer action is rejected.

use aiken/collection/list
use aiken/collection/pairs
use cardano/assets.{PolicyId}
use cardano/transaction.{InlineDatum, OutputReference, Spend, Transaction}
use pool.{ApplyDeposit, ApplyWithdraw, Close, PoolRedeemer}
use types.{Asset, PoolDatum}

pub type CTokenRedeemer {
  pool_in_idx: Int,
}

pub type CTokenParams {
  pool_id: OutputReference,
  pool_nft: Asset,
}

validator ctoken(params: CTokenParams) {
  mint(redeemer: CTokenRedeemer, _policy_id: PolicyId, self: Transaction) {
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
      ApplyDeposit { .. } -> True
      ApplyWithdraw { .. } -> True
      Close -> True
      _ -> False
    }
  }

  else(_) {
    fail
  }
}
