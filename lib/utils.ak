use aiken/builtin
use aiken/collection/dict
use aiken/collection/list
use aiken/interval.{Finite}
use aiken/primitive/bytearray
use aiken/primitive/string
use cardano/address.{Script}
use cardano/assets.{PolicyId, Value}
use cardano/transaction.{Input, Output, ValidityRange}
use types.{Asset, PoolInfoDatum}

pub const multiplier = 10_000

pub const year_in_milliseconds = 31_536_000_000

const minus_ascii_code = 45

const zero_ascii_code = 48

pub fn check_correct_input_payment_credential(
  input: Input,
  expected_script_hash: ByteArray,
) -> Bool {
  when input.output.address.payment_credential is {
    Script(script_hash) -> script_hash == expected_script_hash
    _ -> False
  }
}

pub fn find_posix_time_range(time_rage: ValidityRange) -> (Int, Int) {
  expect Finite(t1) = time_rage.lower_bound.bound_type
  expect Finite(t2) = time_rage.upper_bound.bound_type
  (t1, t2)
}

pub fn find_license_deadline(license_symbol: PolicyId, val: Value) -> Int {
  expect [Pair(tn, am)] =
    val
      |> assets.tokens(license_symbol)
      |> dict.to_pairs()
  expect am == 1
  bytearray_to_int(tn)
}

pub fn bytearray_to_int(byte_arr: ByteArray) -> Int {
  let byte_len = bytearray.length(byte_arr)
  do_bytearray_to_int(byte_arr, 0, 0, byte_len)
}

pub fn do_bytearray_to_int(
  byte_arr: ByteArray,
  idx: Int,
  acc: Int,
  byte_len: Int,
) -> Int {
  if idx == byte_len {
    acc
  } else {
    let byte = builtin.index_bytearray(byte_arr, idx)
    if idx == 0 && byte == minus_ascii_code {
      do_bytearray_to_int(byte_arr, idx + 1, acc, byte_len) * -1
    } else if byte < zero_ascii_code || byte > zero_ascii_code + 9 {
      fail
    } else {
      do_bytearray_to_int(
        byte_arr,
        idx + 1,
        acc * 10 + ( byte - zero_ascii_code ),
        byte_len,
      )
    }
  }
}

test test_bytearray_to_int() {
  let r1 = bytearray_to_int(string.to_bytearray(@"123"))
  let r2 = bytearray_to_int(string.to_bytearray(@"111"))
  r1 == 123 && r2 == 111
}

pub fn cal_interest_rate(u: Int, pool_info_datum: PoolInfoDatum) -> Int {
  when u < pool_info_datum.kink is {
    True ->
      pool_info_datum.base_rate + u * pool_info_datum.slope_low / multiplier
    False ->
      pool_info_datum.base_rate + pool_info_datum.kink * pool_info_datum.slope_low / multiplier + (
        u - pool_info_datum.kink
      ) * pool_info_datum.slope_high / multiplier
  }
}

pub fn cal_ltv(
  payment: Int,
  c_amount: Int,
  o_price: Int,
  o_decimals: Int,
) -> Int {
  payment * multiplier * o_decimals / ( c_amount * o_price )
}

pub fn count_input_orders(
  inputs: List<Input>,
  order_script_hash: ByteArray,
) -> Int {
  list.foldl(
    inputs,
    0,
    fn(input, acc) {
      when input.output.address.payment_credential is {
        Script(script_hash) ->
          if script_hash == order_script_hash {
            acc + 1
          } else {
            acc
          }
        _ -> acc
      }
    },
  )
}

pub fn count_input_orders_with_auth_token(
  inputs: List<Input>,
  order_script_hash: ByteArray,
  auth_token: Asset,
) -> Int {
  list.foldl(
    inputs,
    0,
    fn(input, acc) {
      when input.output.address.payment_credential is {
        Script(script_hash) ->
          if script_hash == order_script_hash && assets.quantity_of(
            input.output.value,
            auth_token.policy_id,
            auth_token.asset_name,
          ) == 1 {
            acc + 1
          } else {
            acc
          }
        _ -> acc
      }
    },
  )
}
