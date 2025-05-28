// Pool Info Validator controls the pool info UTxO containing all the pool parameters.
//
// This validator is parameterized by the admin public key hash (admin_pkh).
//
// Redeemer actions and their validation logic:
//   - spend (default action):
//       * Allows spending of the pool info UTxO.
//       * Checks:
//           - The transaction is signed by the admin (params.admin_pkh).
//           - No other checks are performed; only the admin can update or move the pool info UTxO.
//       * Used for updating pool parameters or moving the pool info UTxO under admin control.

use aiken/collection/dict
use aiken/collection/list
use aiken/interval
use cardano/assets
use cardano/transaction.{OutputReference, Transaction}
use test_constants.{t_admin_pkh, test_get_pool_info}
use types.{PoolInfoDatum}

pub type PoolInfoParams {
  admin_pkh: ByteArray,
}

validator pool_info(params: PoolInfoParams) {
  spend(
    _datum: Option<PoolInfoDatum>,
    _redeemer: Data,
    _utxo: OutputReference,
    self: Transaction,
  ) {
    let Transaction { extra_signatories, .. } = self
    list.has(extra_signatories, params.admin_pkh)
  }

  else(_) {
    fail
  }
}

test pool_info_spend() {
  let (pool_info_input, pool_info_datum) = test_get_pool_info()
  let tx =
    Transaction {
      inputs: [pool_info_input],
      reference_inputs: [],
      outputs: [],
      fee: 0,
      mint: assets.zero,
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
  let params = PoolInfoParams { admin_pkh: t_admin_pkh }
  pool_info.spend(
    params,
    Some(pool_info_datum),
    0,
    pool_info_input.output_reference,
    tx,
  )
}
