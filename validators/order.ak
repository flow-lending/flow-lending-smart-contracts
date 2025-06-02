// Order validator where user orders (deposit, withdraw, borrow, repay, liquidate) are held.
//
// This validator is parameterized by pool id and pool NFT for a specific single pool asset.
//
// Orders can be:
//   - Applied to the pool: If the pool UTxO is spent, logic validation is delegated to the pool validator.
//   - Cancelled by the user: Allows the order owner to cancel their order.
//
// Redeemer actions and their validation logic:
//
// OrderRedeemer:
//   - Apply { pool_in_idx: Int }
//       * Applies the order to the pool by referencing the pool input at the given index.
//       * Checks:
//           - The referenced pool input exists at pool_in_idx in transaction inputs.
//           - The pool input contains a valid PoolDatum inline datum.
//           - The pool_id in the datum matches the expected pool_id in parameters.
//           - The pool NFT is present in the pool input value.
//       * Delegates further validation to the pool validator.
//
//   - Cancel { order_in_idx: Int }
//       * Cancels the order by referencing the order input at the given index.
//       * Checks:
//           - The referenced order input exists at order_in_idx in transaction inputs.
//           - The order input's output reference matches the validator's own reference.
//           - The order input contains a valid OrderDatum inline datum.
//           - The pool_id in the order datum matches the expected pool_id in parameters.
//           - The transaction is signed by the order owner (o_owner_pkh).
//       * Allows only the order owner to cancel their order.

use aiken/collection/list
use cardano/assets
use cardano/transaction.{InlineDatum, OutputReference, Transaction}
use types.{
  Asset, OBorrow, ODeposit, OLiquidate, ORepay, OWithdraw, OrderDatum, PoolDatum,
}

pub type OrderRedeemer {
  Apply { pool_in_idx: Int }
  Cancel { order_in_idx: Int }
}

pub type OrderParams {
  pool_id: OutputReference,
  pool_nft: Asset,
}

validator order(params: OrderParams) {
  spend(
    _datum: Option<Data>,
    redeemer: OrderRedeemer,
    own_ref: OutputReference,
    self: Transaction,
  ) {
    let Transaction { inputs, extra_signatories, .. } = self
    when redeemer is {
      Apply { pool_in_idx } -> {
        expect Some(pool_input) = list.at(inputs, pool_in_idx)
        expect InlineDatum(pool_inline_datum) = pool_input.output.datum
        expect pool_datum: PoolDatum = pool_inline_datum
        expect pool_datum.pool_id == params.pool_id
        assets.quantity_of(
          pool_input.output.value,
          params.pool_nft.policy_id,
          params.pool_nft.asset_name,
        ) == 1
      }
      Cancel { order_in_idx } -> {
        expect Some(order_input) = list.at(inputs, order_in_idx)
        expect order_input.output_reference == own_ref
        expect InlineDatum(order_inline_datum) = order_input.output.datum
        expect order_datum: OrderDatum = order_inline_datum
        when order_datum is {
          ODeposit { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          OWithdraw { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          OBorrow { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          ORepay { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
          OLiquidate { o_pool_id, o_owner_pkh, .. } -> {
            expect o_pool_id == params.pool_id
            list.has(extra_signatories, o_owner_pkh)
          }
        }
      }
    }
  }

  else(_) {
    fail
  }
}

test add_value() {
  let value =
    assets.zero
      |> assets.add(assets.ada_policy_id, assets.ada_asset_name, -1000)
  assets.match(assets.zero, value, >=)
}
