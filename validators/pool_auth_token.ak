// Validator to mint authorization tokens for pool and pool info NFTs, ensuring valid datums.
//
// This validator is parameterized by the pool id and admin public key hash.
//
// Redeemer actions and their validation logic:
//
// MintRedeemer:
//   - Mint { pool_info_out_idx: Int, pool_out_idx: Int }
//       * Mints both the pool info NFT and the pool NFT.
//       * Checks:
//           - The transaction is signed by the admin (params.admin_pkh).
//           - The correct assets (pool info NFT and pool NFT) are minted (quantity 1 each).
//           - The referenced outputs at pool_info_out_idx and pool_out_idx exist in transaction outputs.
//           - Each output contains the correct NFT and only two assets in total.
//           - Each output contains a valid inline datum:
//               - PoolInfoDatum: Must pass is_pool_info_datum_valid (checks for positive and valid parameters).
//               - PoolDatum: Must pass is_pool_datum_valid (checks for initial zeroed state).
//           - The minted assets exactly match the expected merged_mint value.
//   - Burn
//       * Burns the pool info NFT and/or pool NFT.
//       * Checks:
//           - The transaction is signed by the admin (params.admin_pkh).

use aiken/collection/dict
use aiken/collection/list
use aiken/interval
use cardano/address.{Address, Script, from_verification_key}
use cardano/assets.{PolicyId, flatten}
use cardano/transaction.{
  InlineDatum, Input, NoDatum, Output, OutputReference, Transaction,
}
use constants.{pool_info_nft_tn, pool_nft_tn}
use test_constants.{
  t_admin_pkh, t_init_pool_output, t_pool_authtoken_policy_id, t_pool_id,
  t_pool_info_output, t_pool_info_script_hash, t_pool_script_hash,
}
use types.{PoolDatum, PoolInfoDatum}

pub type MintRedeemer {
  Mint {
    pool_info_out_idx: Int,
    pool_out_idx: Int,
    pool_info_script: ByteArray,
    pool_script_hash: ByteArray,
  }
  Burn
}

fn is_pool_info_datum_valid(pool_info_datum: PoolInfoDatum) -> Bool {
  expect pool_info_datum.envelope_amount > 0
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
    let Transaction { inputs, outputs, mint, extra_signatories, .. } = self
    when redeemer is {
      Mint {
        pool_info_out_idx,
        pool_out_idx,
        pool_info_script,
        pool_script_hash,
      } -> {
        expect list.has(extra_signatories, params.admin_pkh)
        let pool_info_nft = assets.from_asset(policy_id, pool_info_nft_tn, 1)
        let pool_nft = assets.from_asset(policy_id, pool_nft_tn, 1)
        let merged_mint = assets.merge(pool_info_nft, pool_nft)
        expect Some(pool_info_output) = list.at(outputs, pool_info_out_idx)
        expect Some(pool_output) = list.at(outputs, pool_out_idx)
        let pool_info_script_cred = Script(pool_info_script)
        let pool_script_cred = Script(pool_script_hash)
        let Output {
          address: Address {
            payment_credential: pool_info_payment_credential,
            ..
          },
          ..
        } = pool_info_output
        let Output {
          address: Address { payment_credential: pool_payment_credential, .. },
          ..
        } = pool_output
        expect pool_info_payment_credential == pool_info_script_cred
        expect pool_payment_credential == pool_script_cred
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
        expect pool_datum.pool_id == params.pool_id
        expect pool_info_datum.pool_id == params.pool_id
        expect
          list.any(
            inputs,
            fn(input) { input.output_reference == params.pool_id },
          )
        expect merged_mint == mint
        True
      }
      Burn -> {
        expect
          list.foldl(
            flatten(mint),
            True,
            fn(curr, acc) {
              let (_, _, quantity) = curr
              acc && quantity < 0
            },
          )
        list.has(extra_signatories, params.admin_pkh)
      }
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
  let redeemer =
    Mint {
      pool_info_out_idx: 0,
      pool_out_idx: 1,
      pool_info_script: t_pool_info_script_hash,
      pool_script_hash: t_pool_script_hash,
    }
  let params =
    PoolAuthTokenParams { pool_id: t_pool_id, admin_pkh: t_admin_pkh }
  pool_auth_token.mint(params, redeemer, own_policy_id, tx)
}
