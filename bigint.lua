--[[
The MIT License (MIT)

Copyright (c) 2020 Eduardo Bart (https://github.com/edubart)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

--[[--
Small portable arbitrary-precision integer arithmetic library in pure Lua for
computing with large integers.

Different from most arbitrary-precision integer libraries in pure Lua out there this one
uses an array of lua integers as underlying data-type in its implementation instead of
using strings or large tables, so regarding that aspect this library should be more efficient.

## Design goals

The main design goal of this library is to be small, correct, self contained and use few
resources while retaining acceptable performance and feature completeness.
Clarity of the code is also highly valued.

The library is designed to follow recent Lua integer semantics, this means that
integer overflow warps around,
signed integers are implemented using two-complement arithmetic rules,
integer division operations rounds towards minus infinity,
any mixed operations with float numbers promotes the value to a float,
and the usual division/power operation always promote floats.

The library is designed to be possible to work with only unsigned integer arithmetic
when using the proper methods.

All the lua arithmetic operators (+, -, *, //, /, %) and bitwise operators (&, |, ~, <<, >>)
are implemented as metamethods.

## Usage

First on you should configure how many bits the library will work with,
to do that call @{bigint.scale} once on startup with the desired number of bits in multiples of 32,
for example bigint.scale(1024).
By default bigint uses 256 bits integers in case you never call scale.

Then when you need create a bigint, you can use one of the following functions:

* @{bigint.fromuinteger} (convert from lua integers, but read as unsigned integer)
* @{bigint.frominteger} (convert from lua integers, preserving the sign)
* @{bigint.fromnumber} (convert from lua floats, truncating the fractional part)
* @{bigint.frombase} (convert from arbitrary bases, like hexadecimal)
* @{bigint.new} (convert from anything, asserts on invalid values)
* @{bigint.convert} (convert form anything, returns nil on invalid values)
* @{bigint.parse} (convert from anything, returns a lua number as fallback)
* @{bigint.zero}
* @{bigint.one}
* `bigint`

You can also call `bigint` as it is an alias to `bigint.new`.
In doubt use @{bigint.new} to create a new bigint.

Then you can use all the usual lua numeric operations on it,
all the arithmetic metamethods are implemented.
When you are done computing and need to get the result,
get the output from one of the following functions:

* @{bigint.touinteger} (convert to a lua integer, wraps around as an unsigned integer)
* @{bigint.tointeger} (convert to a lua integer, always preserving the sign)
* @{bigint.tonumber} (convert to lua float, losing precision)
* @{bigint.tobase} (convert to a string in any base)
* @{bigint.__tostring} (convert to a string in base 10)

Note that outputting to a lua number will make the integer overflow and its value wraps around.
To output very large integer with no loss of precision you probably want to use @{bigint.tobase}
or call `tostring` to get a string representation.

## Precautions

All library functions can be mixed with lua numbers,
this makes easy to mix operations between bigints and lua numbers,
however the user should take care in some situations:

* Don't mix integers and float operations if you want to work with integers only.
* Don't use the regular equal operator ('==') to compare values from this library,
unless you know in advance that both values are of the same primitive type,
otherwise it will always returns false, use @{bigint.eq} to be safe.
* Don't pass fractional numbers to functions that an integer is expected
as this will throw assertions.
* Remember that casting back to lua integers or numbers precision can be lost.
* For dividing while preserving integers use the @{bigint.__idiv} (the '//' operator).
* For doing power operation preserving integers use the @{bigint.ipow} function.
* Configure the internal integer fixed width using @{bigint.scale}
to the proper size you intend to work with, otherwise large integers may wraps around.

]]

local bigint = {}
bigint.__index = bigint

-- Constants used internally and modified by bigint.scale
local BIGINT_SIZE
local BIGINT_WORDBITS
local BIGINT_WORDMAX
local BIGINT_SIGNBIT
local BIGINT_HALFMAX
local BIGINT_MATHMININTEGER
local BIGINT_MATHMAXINTEGER

-- Returns number of bits of the internal lua integer type.
local function luainteger_bitsize()
  local n = -1
  local i = 0
  repeat
    i = i + 1
    n = n >> 1
  until n==0
  return i
end

--- Scale bigint's integer width to represent integers of the desired bit size.
-- Must be called only once on startup.
-- @param bits Number of bits for the integer representation, must be multiple of wordbits and
-- at least 64.
-- @param[opt] wordbits Number of the bits for the internal world, defaults to 32.
function bigint.scale(bits, wordbits)
  wordbits = wordbits or 32
  assert(bits % wordbits == 0, 'bitsize is not multiple of word bitsize')
  assert(2*wordbits <= luainteger_bitsize(), 'word bitsize must be half of the lua integer bitsize')
  assert(bits >= 64, 'bitsize must be >= 64')
  BIGINT_SIZE = bits / wordbits
  BIGINT_WORDBITS = wordbits
  BIGINT_WORDMAX = (1 << BIGINT_WORDBITS) - 1
  BIGINT_SIGNBIT = (1 << (BIGINT_WORDBITS - 1))
  BIGINT_HALFMAX = 1 + BIGINT_WORDMAX // 2
  BIGINT_MATHMININTEGER = bigint.new(math.mininteger)
  BIGINT_MATHMAXINTEGER = bigint.new(math.maxinteger)
end

-- Create a new bigint without initializing.
local function bigint_newempty()
  return setmetatable({}, bigint)
end

-- Convert a value to a lua integer without losing precision.
local function tointeger(x)
  x = tonumber(x)
  if math.type(x) == 'float' then
    local floorx = math.floor(x)
    if floorx ~= x then
      return nil
    end
    x = floorx
  end
  return x
end

-- Check if the input is a bigint.
local function isbigint(x)
  return getmetatable(x) == bigint
end

-- Assign bigint to an unsigned integer.  Used only internally.
function bigint:_fromuinteger(x)
  for i=1,BIGINT_SIZE do
    self[i] = x & BIGINT_WORDMAX
    x = x >> BIGINT_WORDBITS
  end
  return self
end

--- Create a bigint from an unsigned integer.
-- Treats signed integers as an unsigned integer.
-- @param x A value to initialize from convertible to a lua integer.
-- @return A new bigint or nil in case the input cannot be represented by an integer.
-- @see bigint.frominteger
function bigint.fromuinteger(x)
  x = tointeger(x)
  if not x then
    return nil
  elseif x == 1 then
    return bigint.one()
  elseif x == 0 then
    return bigint.zero()
  end
  return bigint_newempty():_fromuinteger(x)
end

--- Create a bigint from a signed integer.
-- @param x A value to initialize from convertible to a lua integer.
-- @return A new bigint or nil in case the input cannot be represented by an integer.
-- @see bigint.fromuinteger
function bigint.frominteger(x)
  x = tointeger(x)
  if not x then
    return nil
  elseif  x == 1 then
    return bigint.one()
  elseif x == 0 then
    return bigint.zero()
  end
  local neg = false
  if x < 0 then
    x = math.abs(x)
    neg = true
  end
  local n = bigint_newempty():_fromuinteger(x)
  if neg then
    n:_unm()
  end
  return n
end

--- Create a bigint from a number.
-- Floats values are truncated, that is, the fractional port is discarded.
-- @param x A value to initialize from convertible to a lua number.
-- @return A new bigint or nil in case the input cannot be represented by an integer.
function bigint.fromnumber(x)
  x = tonumber(x)
  if not x then
    return nil
  end
  local ty = math.type(x)
  if ty == 'float' then
    -- truncate to integer
    x = math.modf(x)
  end
  return bigint.frominteger(x)
end

local basesteps = {}

-- Compute the read/write step for frombase/tobase functions.
local function getbasestep(base)
  local step = basesteps[base]
  if step then
    return step
  end
  step = 0
  local dmax = 1
  local limit = math.maxinteger // base
  repeat
    step = step + 1
    dmax = dmax * base
  until dmax >= limit
  basesteps[base] = step
  return step
end

-- Compute power with lua integers.
local function ipow(x, y)
  local r = 1
  for _=1,y do
    r = r * x
  end
  return r
end

--- Create a bigint from a string of the desired base.
-- @param s The string to be converted from,
-- must have only alphanumeric and '+-' characters.
-- @param[opt] base Base that the number is represented, defaults to 10.
-- Must be at least 2 and at most 36.
-- @return A new bigint or nil in case the conversion failed.
function bigint.frombase(s, base)
  if type(s) ~= 'string' then
    return nil
  end
  s = s:lower()
  base = base or 10
  if not (base >= 2 and base <= 36) then
    -- number base is too large
    return nil
  end
  local sign, int = s:match('^([+-]?)(%w+)$')
  if not (sign and int) then
    -- invalid integer string representation
    return nil
  end
  local n = bigint.zero()
  local step = getbasestep(base)
  for i=1,#int,step do
    local part = int:sub(i,i+step-1)
    local d = tonumber(part, base)
    if not d then
      -- invalid integer string representation
      return nil
    end
    n = (n * ipow(base, #part)):_add(d)
  end
  if sign == '-' then
    n:_unm()
  end
  return n
end

--- Convert a bigint to an unsigned integer.
-- Note that large unsigned integers may be represented as negatives in lua integers.
-- Note that lua cannot represent values larger than 64 bits,
-- in that case integer values wraps around.
-- @param x A bigint or a number to be converted into an unsigned integer.
-- @return An integer or nil in case the input cannot be represented by an integer.
-- @see bigint.tointeger
function bigint.touinteger(x)
  if isbigint(x) then
    local n = 0
    for i=1,BIGINT_SIZE do
      n = n | (x[i] << (BIGINT_WORDBITS * (i - 1)))
    end
    return n
  else
    return tointeger(x)
  end
end

--- Convert a bigint to a signed integer.
-- It works by taking absolute values then applying the sign bit in case needed.
-- Note that lua cannot represent values larger than 64 bits,
-- in that case integer values wraps around.
-- @param x A bigint or value to be converted into an unsigned integer.
-- @return An integer or nil in case the input cannot be represented by an integer.
-- @see bigint.touinteger
function bigint.tointeger(x)
  if isbigint(x) then
    local n = 0
    local neg = x:isneg()
    if neg then
      x = -x
    end
    for i=1,BIGINT_SIZE do
      n = n | (x[i] << (BIGINT_WORDBITS * (i - 1)))
    end
    if neg then
      n = -n
    end
    return n
  else
    return tointeger(x)
  end
end

local function bigint_assert_tointeger(x)
  return assert(bigint.tointeger(x), 'value has no integer representation')
end

--- Convert a bigint to a lua number.
-- Different from @{bigint.tointeger} the operation does not wraps around integers,
-- but digits precision may be lost in the process of converting to a float.
-- @param x A bigint or value to be converted into a number.
-- @return An integer or nil in case the input cannot be represented by a number.
-- @see bigint.tointeger
function bigint.tonumber(x)
  if isbigint(x) then
    if x >= BIGINT_MATHMININTEGER and x <= BIGINT_MATHMAXINTEGER then
      return x:tointeger()
    else
      return tonumber(tostring(x))
    end
  else
    return tonumber(x)
  end
end

-- Compute base letters to use in bigint.tobase
local BASE_LETTERS = {}
do
  for i=1,36 do
    BASE_LETTERS[i-1] = ('0123456789abcdefghijklmnopqrstuvwxyz'):sub(i,i)
  end
end

-- Get the quotient and remainder for a lua integer division
local function idivmod(x, y)
  local quot = x // y
  local rem = x - (quot * y)
  return quot, rem
end

--- Convert a bigint to a string in the desired base.
-- @param x The bigint to be converted from.
-- @param[opt] base Base to be represented, defaults to 10.
-- Must be at least 2 and at most 36.
-- @param[opt] unsigned Whether to output as unsigned integer.
-- Defaults to true for base 10 and false for others.
-- @return A string representing the input.
-- @raise An assert is thrown in case the base is invalid.
function bigint.tobase(x, base, unsigned)
  x = bigint.convert(x)
  if not x then
    -- x is a fractional float or something else
    return nil
  end
  base = base or 10
  if not (base >= 2 and base <= 36) then
    -- number base is too large
    return nil
  end
  local ss = {}
  if unsigned == nil then
    unsigned = base ~= 10
  end
  local neg = not unsigned and x:isneg()
  if neg then
    x = x:abs()
  end
  local step = getbasestep(base)
  local divisor = ipow(base, step)
  local stop = x:iszero()
  if stop then
    return '0'
  end
  while not stop do
    local ix
    x, ix = bigint.udivmod(x, divisor)
    ix = ix:tointeger()
    stop = x:iszero()
    for _=1,step do
      local d
      ix, d = idivmod(ix, base)
      if stop and ix == 0 and d == 0 then
        -- stop on leading zeros
        break
      end
      table.insert(ss, 1, BASE_LETTERS[d])
    end
  end
  if neg then
    table.insert(ss, 1, '-')
  end
  return table.concat(ss)
end

-- Convert lua numbers and strings to a bigint
local function bigint_fromvalue(x)
  local ty = type(x)
  if ty == 'number' then
    return bigint.frominteger(x)
  elseif ty == 'string' then
    return bigint.frombase(x, 10)
  end
  return nil
end

--- Create a new bigint from a value.
-- @param x A value convertible to a bigint (string, number or another bigint).
-- @return A new bigint, guaranteed to be a new reference in case needed.
-- @raise An assert is thrown in case x is not convertible to a bigint.
-- @see bigint.convert
-- @see bigint.parse
function bigint.new(x)
  if isbigint(x) then
    -- return a clone
    local n = {}
    for i=1,BIGINT_SIZE do
      n[i] = x[i]
    end
    return setmetatable(n, bigint)
  else
    x = bigint_fromvalue(x)
  end
  assert(x, 'value cannot be represented by a bigint')
  return x
end

--- Convert a value to a bigint if possible.
-- @param x A value to be converted (string, number or another bigint).
-- @param[opt] clone A boolean that tells if a new bigint reference should be returned.
-- Defaults to false.
-- @return A bigint or nil in case the conversion failed.
-- @see bigint.new
-- @see bigint.parse
function bigint.convert(x, clone)
  if isbigint(x) then
    if clone then
      return bigint.new(x)
    else
      return x
    end
  else
    return bigint_fromvalue(x)
  end
end

local function bigint_assert_convert(x)
  return assert(bigint.convert(x), 'value has not integer representation')
end

--- Convert a value to a bigint if possible otherwise to a lua number.
-- Useful to prepare values that you are unsure if its going to be a integer or float.
-- @param x A value to be converted (string, number or another bigint).
-- @param[opt] clone A boolean that tells if a new bigint reference should be returned.
-- Defaults to false.
-- @return A bigint or a lua number or nil in case the conversion failed.
-- @see bigint.new
-- @see bigint.convert
function bigint.parse(x, clone)
  local i = bigint.convert(x, clone)
  if i then
    return i
  else
    return tonumber(x)
  end
end

--- Check if a number is 0 considering bigints.
-- @param x A bigint or a lua number.
function bigint.iszero(x)
  if isbigint(x) then
    for i=1,BIGINT_SIZE do
      if x[i] ~= 0 then
        return false
      end
    end
    return true
  else
    return x == 0
  end
end

--- Check if a number is 1 considering bigints.
-- @param x A bigint or a lua number.
function bigint.isone(x)
  if isbigint(x) then
    if x[1] ~= 1 then
      return false
    end
    for i=2,BIGINT_SIZE do
      if x[i] ~= 0 then
        return false
      end
    end
    return true
  else
    return x == 1
  end
end

--- Check if a number is -1 considering bigints.
-- @param x A bigint or a lua number.
function bigint.isminusone(x)
  if isbigint(x) then
    for i=1,BIGINT_SIZE do
      if x[i] ~= BIGINT_WORDMAX then
        return false
      end
    end
    return true
  else
    return x == -1
  end
end

--- Check if a number is negative considering bigints.
-- Zero is guaranteed to never be negative for bigints.
-- @param x A bigint or a lua number.
function bigint.isneg(x)
  if isbigint(x) then
    return x[BIGINT_SIZE] & BIGINT_SIGNBIT ~= 0
  else
    return x < 0
  end
end

--- Check if a number is positive considering bigints.
-- @param x A bigint or a lua number.
function bigint.ispos(x)
  if isbigint(x) then
    return not x:isneg() and not x:iszero()
  else
    return x > 0
  end
end

--- Check if a number is even considering bigints.
-- @param x A bigint or a lua number.
function bigint.iseven(x)
  if isbigint(x) then
    return x[1] & 1 == 0
  else
    return math.abs(x) % 2 == 0
  end
end

--- Check if a number is odd considering bigints.
-- @param x A bigint or a lua number.
function bigint.isodd(x)
  if isbigint(x) then
    return x[1] & 1 == 1
  else
    return math.abs(x) % 2 == 1
  end
end

--- Assign a bigint to zero (in-place).
function bigint:_zero()
  for i=1,BIGINT_SIZE do
    self[i] = 0
  end
  return self
end

--- Create a new bigint with 0 value.
function bigint.zero()
  return bigint_newempty():_zero()
end

--- Assign a bigint to 1 (in-place).
function bigint:_one()
  self[1] = 1
  for i=2,BIGINT_SIZE do
    self[i] = 0
  end
  return self
end

--- Create a new bigint with 1 value.
function bigint.one()
  return bigint_newempty():_one()
end

--- Bitwise left shift a bigint in one bit (in-place).
function bigint:_shlone()
  local wordbitsm1 = BIGINT_WORDBITS - 1
  for i=BIGINT_SIZE,2,-1 do
    self[i] = ((self[i] << 1) | (self[i-1] >> wordbitsm1)) & BIGINT_WORDMAX
  end
  self[1] = (self[1] << 1) & BIGINT_WORDMAX
  return self
end

--- Bitwise right shift a bigint in one bit (in-place).
function bigint:_shrone()
  local wordbitsm1 = BIGINT_WORDBITS - 1
  for i=1,BIGINT_SIZE-1 do
    self[i] = ((self[i] >> 1) | (self[i+1] << wordbitsm1)) & BIGINT_WORDMAX
  end
  self[BIGINT_SIZE] = self[BIGINT_SIZE] >> 1
  return self
end

-- Bitwise left shift words of a bigint (in-place). Used only internally.
function bigint:_shlwords(n)
  for i=BIGINT_SIZE,n+1,-1 do
    self[i] = self[i - n]
  end
  for i=1,n do
    self[i] = 0
  end
  return self
end

-- Bitwise right shift words of a bigint (in-place). Used only internally.
function bigint:_shrwords(n)
  if n < BIGINT_SIZE then
    for i=1,BIGINT_SIZE-n+1 do
      self[i] = self[i + n]
    end
    for i=BIGINT_SIZE-n,BIGINT_SIZE do
      self[i] = 0
    end
  else
    for i=1,BIGINT_SIZE do
      self[i] = 0
    end
  end
  return self
end

--- Increment a bigint by one (in-place).
function bigint:_inc()
  for i=1,BIGINT_SIZE do
    local tmp = self[i]
    local v = (tmp + 1) & BIGINT_WORDMAX
    self[i] = v
    if v > tmp then
      break
    end
  end
  return self
end

--- Increment a number by one considering bigints.
-- @param x A bigint or a lua number to increment.
function bigint.inc(x)
  local ix = bigint.convert(x, true)
  if ix then
    return ix:_inc()
  else
    return x + 1
  end
end

--- Decrement a bigint by one (in-place).
function bigint:_dec()
  for i=1,BIGINT_SIZE do
    local tmp = self[i]
    local v = (tmp - 1) & BIGINT_WORDMAX
    self[i] = v
    if not (v > tmp) then
      break
    end
  end
  return self
end

--- Decrement a number by one considering bigints.
-- @param x A bigint or a lua number to decrement.
function bigint.dec(x)
  local ix = bigint.convert(x, true)
  if ix then
    return ix:_dec()
  else
    return x - 1
  end
end

--- Assign a bigint to a new value (in-place).
-- @param y A value to be copied from.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint:_assign(y)
  y = bigint_assert_convert(y)
  for i=1,BIGINT_SIZE do
    self[i] = y[i]
  end
  return self
end

--- Take absolute of a bigint (in-place).
function bigint:_abs()
  if self:isneg() then
    self:_unm()
  end
  return self
end

--- Take absolute of a number considering bigints.
-- @param x A bigint or a lua number to take the absolute.
function bigint.abs(x)
  local ix = bigint.convert(x, true)
  if ix then
    return ix:_abs()
  else
    return math.abs(x)
  end
end

--- Add an integer to a bigint (in-place).
-- @param y An integer to be added.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint:_add(y)
  y = bigint_assert_convert(y)
  local carry = 0
  for i=1,BIGINT_SIZE do
    local tmp = self[i] + y[i] + carry
    carry = tmp > BIGINT_WORDMAX and 1 or 0
    self[i] = tmp & BIGINT_WORDMAX
  end
  return self
end

--- Add two numbers considering bigints.
-- @param x A bigint or a lua number to be added.
-- @param y A bigint or a lua number to be added.
function bigint.__add(x, y)
  local ix = bigint.convert(x, true)
  local iy = bigint.convert(y)
  if ix and iy then
    return ix:_add(iy)
  else
    return bigint.tonumber(x) + bigint.tonumber(y)
  end
end

--- Subtract an integer from a bigint (in-place).
-- @param y An integer to subtract.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint:_sub(y)
  y = bigint_assert_convert(y)
  local borrow = 0
  for i=1,BIGINT_SIZE do
    local tmp1 = self[i] + (BIGINT_WORDMAX + 1)
    local tmp2 = y[i] + borrow
    local res = tmp1 - tmp2
    self[i] = res & BIGINT_WORDMAX
    borrow = res <= BIGINT_WORDMAX and 1 or 0
  end
  return self
end

--- Subtract two numbers considering bigints.
-- @param x A bigint or a lua number to be subtract from.
-- @param y A bigint or a lua number to subtract.
function bigint.__sub(x, y)
  local ix = bigint.convert(x, true)
  local iy = bigint.convert(y)
  if ix and iy then
    return ix:_sub(iy)
  else
    return bigint.tonumber(x) - bigint.tonumber(y)
  end
end

--- Multiply two numbers considering bigints.
-- @param x A bigint or a lua number to multiply.
-- @param y A bigint or a lua number to multiply.
function bigint.__mul(x, y)
  local ix = bigint.convert(x)
  local iy = bigint.convert(y)
  if ix and iy then
    local row, tmp = bigint_newempty(), bigint_newempty()
    local res = bigint.zero()
    for i=1,BIGINT_SIZE do
      row:_zero()
      for j=1,BIGINT_SIZE do
        local nshifts = i+j-2
        if nshifts < BIGINT_SIZE then
          row:_add(tmp:_fromuinteger(ix[i] * iy[j]):_shlwords(nshifts))
        end
      end
      res:_add(row)
    end
    return res
  else
    return bigint.tonumber(x) * bigint.tonumber(y)
  end
end

--- Perform unsigned division between two integers considering bigints.
-- @param x The numerator, must be a bigint or a lua integer.
-- @param y The denominator, must be a bigint or a lua integer.
-- @return The quotient, a bigint.
-- @raise Asserts on attempt to divide by zero
-- or if inputs are not convertible to integers.
function bigint.udiv(x, y)
  local current = bigint.one()
  local dividend = bigint.new(x)
  local denom = bigint.new(y)
  assert(not denom:iszero(), 'attempt to divide by zero')
  local overflow = false
  while denom:ule(dividend) do
    if denom[BIGINT_SIZE] >= BIGINT_HALFMAX then
      overflow = true
      break
    end
    current:_shlone()
    denom:_shlone()
  end
  if not overflow then
    current:_shrone()
    denom:_shrone()
  end
  local quot = bigint.zero()
  while not current:iszero() do
    if denom:ule(dividend) then
      dividend:_sub(denom)
      quot:_bor(current)
    end
    current:_shrone()
    denom:_shrone()
  end
  return quot
end

--- Perform unsigned division and modulo operation between two integers considering bigints.
-- This is effectively the same of @{bigint.udiv} and @{bigint.umod}.
-- @param x The numerator, must be a bigint or a lua integer.
-- @param y The denominator, must be a bigint or a lua integer.
-- @return The quotient following the remainder, both bigints.
-- @raise Asserts on attempt to divide by zero
-- or if inputs are not convertible to integers.
-- @see bigint.udiv
-- @see bigint.umod
function bigint.udivmod(x, y)
  x, y = bigint_assert_convert(x), bigint_assert_convert(y)
  local quot = bigint.udiv(x, y)
  local rem = x - (quot * y)
  return quot, rem
end

--- Perform unsigned integer modulo operation between two integers considering bigints.
-- @param x The numerator, must be a bigint or a lua integer.
-- @param y The denominator, must be a bigint or a lua integer.
-- @return The remainder, a bigint.
-- @raise Asserts on attempt to divide by zero
-- or if the inputs are not convertible to integers.
function bigint.umod(x, y)
  local _, rem = bigint.udivmod(x, y)
  return rem
end

--- Perform floor division between two numbers considering bigints.
-- Floor division is a division that rounds the quotient towards minus infinity,
-- resulting in the floor of the division of its operands.
-- @param x The numerator, a bigint or lua number.
-- @param y The denominator, a bigint or lua number.
-- @return The quotient, a bigint or lua number.
-- @raise Asserts on attempt to divide by zero.
function bigint.__idiv(x, y)
  local ix = bigint.convert(x)
  local iy = bigint.convert(y)
  if ix and iy then
    if iy:isminusone() then
      return -ix
    end
    local quot = bigint.udiv(ix:abs(), iy:abs())
    if ix:isneg() ~= iy:isneg() then
      quot:_unm()
      -- round quotient towards minus infinity
      local rem = ix - (iy * quot)
      if not rem:iszero() then
        quot:_dec()
      end
    end
    return quot
  else
    return bigint.tonumber(x) // bigint.tonumber(y)
  end
end

--- Perform division between two numbers considering bigints.
-- This always cast inputs to floats, for integer division only use @{bigint.__idiv}.
-- @param x The numerator, a bigint or lua number.
-- @param y The denominator, a bigint or lua number.
-- @return The quotient, a lua number.
function bigint.__div(x, y)
  return bigint.tonumber(x) / bigint.tonumber(y)
end

--- Perform integer floor division and modulo operation between two numbers considering bigints.
-- This is effectively the same of @{bigint.__idiv} and @{bigint.__mod}.
-- @param x The numerator, a bigint or lua number.
-- @param y The denominator, a bigint or lua number.
-- @return The quotient following the remainder, both bigint or lua number.
-- @raise Asserts on attempt to divide by zero.
-- @see bigint.__idiv
-- @see bigint.__mod
function bigint.idivmod(x, y)
  local ix = bigint.convert(x)
  local iy = bigint.convert(y)
  if ix and iy then
    return idivmod(ix, iy)
  else
    return idivmod(bigint.tonumber(x), bigint.tonumber(y))
  end
end

--- Perform integer floor modulo operation between two numbers considering bigints.
-- The operation is defined as the remainder of the floor division
-- (division that rounds the quotient towards minus infinity).
-- @param x The numerator, a bigint or lua number.
-- @param y The denominator, a bigint or lua number.
-- @return The remainder, a bigint or lua number.
-- @raise Asserts on attempt to divide by zero.
function bigint.__mod(x, y)
  local _, rem = bigint.idivmod(x, y)
  return rem
end

--- Perform integer power between two integers considering bigints.
-- @param x The base, an integer.
-- @param y The exponent, cannot be negative, an integer.
-- @return The result of the pow operation, a bigint.
-- @raise Asserts on attempt to pow with a negative exponent
-- or if inputs are not convertible to integers.
-- @see bigint.__pow
function bigint.ipow(x, y)
  y = bigint_assert_convert(y)
  assert(not y:isneg(), "attempt to pow to a negative power")
  if y:iszero() then
    return bigint.one()
  elseif y:isone() then
    return bigint.new(x)
  end
  -- compute exponentiation by squaring
  x, y = bigint.new(x),  bigint.new(y)
  local z = bigint.one()
  repeat
    if y:iseven() then
      x = x * x
      y:_shrone()
    else
      z = x * z
      x = x * x
      y:_dec():_shrone()
    end
  until y:isone()
  return x * z
end

--- Perform numeric power between two numbers considering bigints.
-- This always cast inputs to floats, for integer power only use @{bigint.ipow}.
-- @param x The base, a bigint or lua number.
-- @param y The exponent, a bigint or lua number.
-- @return The result of the pow operation, a lua number.
-- @see bigint.ipow
function bigint.__pow(x, y)
  return bigint.tonumber(x) ^ bigint.tonumber(y)
end

--- Bitwise left shift integers considering bigints.
-- @param x An integer to perform the bitwise shift.
-- @param y An integer with the number of bits to shift.
-- @return The result of shift operation, a bigint.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint.__shl(x, y)
  x, y = bigint.new(x), bigint_assert_tointeger(y)
  if y < 0 then
    return x >> -y
  end
  local nvals = y // BIGINT_WORDBITS
  if nvals ~= 0 then
    x:_shlwords(nvals)
    y = y - nvals * BIGINT_WORDBITS
  end
  if y ~= 0 then
    local wordbitsmy = BIGINT_WORDBITS - y
    for i=BIGINT_SIZE,2,-1 do
      x[i] = ((x[i] << y) | (x[i-1] >> wordbitsmy)) & BIGINT_WORDMAX
    end
    x[1] = (x[1] << y) & BIGINT_WORDMAX
  end
  return x
end

--- Bitwise right shift integers considering bigints.
-- @param x An integer to perform the bitwise shift.
-- @param y An integer with the number of bits to shift.
-- @return The result of shift operation, a bigint.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint.__shr(x, y)
  x, y = bigint.new(x), bigint_assert_tointeger(y)
  if y < 0 then
    return x << -y
  end
  local nvals = y // BIGINT_WORDBITS
  if nvals ~= 0 then
    x:_shrwords(nvals)
    y = y - nvals * BIGINT_WORDBITS
  end
  if y ~= 0 then
    local wordbitsmy = BIGINT_WORDBITS - y
    for i=1,BIGINT_SIZE-1 do
      x[i] = ((x[i] >> y) | (x[i+1] << wordbitsmy)) & BIGINT_WORDMAX
    end
    x[BIGINT_SIZE] = x[BIGINT_SIZE] >> y
  end
  return x
end

--- Bitwise AND bigints (in-place).
-- @param y An integer to perform bitwise AND.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint:_band(y)
  y = bigint_assert_convert(y)
  for i=1,BIGINT_SIZE do
    self[i] = self[i] & y[i]
  end
  return self
end

--- Bitwise AND two integers considering bigints.
-- @param x An integer to perform bitwise AND.
-- @param y An integer to perform bitwise AND.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint.__band(x, y)
  return bigint.new(x):_band(y)
end

--- Bitwise OR bigints (in-place).
-- @param y An integer to perform bitwise OR.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint:_bor(y)
  y = bigint_assert_convert(y)
  for i=1,BIGINT_SIZE do
    self[i] = self[i] | y[i]
  end
  return self
end

--- Bitwise OR two integers considering bigints.
-- @param x An integer to perform bitwise OR.
-- @param y An integer to perform bitwise OR.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint.__bor(x, y)
  return bigint.new(x):_bor(y)
end

--- Bitwise XOR bigints (in-place).
-- @param y An integer to perform bitwise XOR.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint:_bxor(y)
  y = bigint_assert_convert(y)
  for i=1,BIGINT_SIZE do
    self[i] = self[i] ~ y[i]
  end
  return self
end

--- Bitwise XOR two integers considering bigints.
-- @param x An integer to perform bitwise XOR.
-- @param y An integer to perform bitwise XOR.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint.__bxor(x, y)
  return bigint.new(x):_bxor(y)
end

--- Bitwise NOT a bigint (in-place).
function bigint:_bnot()
  for i=1,BIGINT_SIZE do
    self[i] = (~self[i]) & BIGINT_WORDMAX
  end
  return self
end

--- Bitwise NOT a bigint.
-- @param x An integer to perform bitwise NOT.
-- @raise Asserts in case inputs are not convertible to integers.
function bigint.__bnot(x)
  return bigint.new(x):_bnot()
end

--- Negate a bigint (in-place). This apply effectively apply two's complements.
function bigint:_unm()
  return self:_bnot():_inc()
end

--- Negate a bigint. This apply effectively apply two's complements.
-- @param x A bigint to perform negation.
function bigint.__unm(x)
  return bigint.new(x):_unm()
end

--- Check if bigints are equal.
-- @param x A bigint to compare.
-- @param y A bigint to compare.
function bigint.__eq(x, y)
  for i=1,BIGINT_SIZE do
    if x[i] ~= y[i] then
      return false
    end
  end
  return true
end

--- Check if numbers are equal considering bigints.
-- @param x A bigint or lua number to compare.
-- @param y A bigint or lua number to compare.
function bigint.eq(x, y)
  local ix = bigint.convert(x)
  local iy = bigint.convert(y)
  if ix and iy then
    return ix == iy
  else
    return x == y
  end
end

--- Compare if integer x is less than y considering bigints (unsigned version).
-- @param x Left integer to compare.
-- @param y Right integer to compare.
-- @raise Asserts in case inputs are not convertible to integers.
-- @see bigint.__lt
function bigint.ult(x, y)
  x, y = bigint_assert_convert(x), bigint_assert_convert(y)
  for i=BIGINT_SIZE,1,-1 do
    if x[i] < y[i] then
      return true
    elseif x[i] > y[i] then
      return false
    end
  end
  return false
end

--- Compare if bigint x is less or equal than y considering bigints (unsigned version).
-- @param x Left integer to compare.
-- @param y Right integer to compare.
-- @raise Asserts in case inputs are not convertible to integers.
-- @see bigint.__le
function bigint.ule(x, y)
  x, y = bigint_assert_convert(x), bigint_assert_convert(y)
  for i=BIGINT_SIZE,1,-1 do
    if x[i] < y[i] then
      return true
    elseif x[i] ~= y[i] then
      return false
    end
  end
  return true
end

--- Compare if number x is less than y considering bigints and signs.
-- @param x Left value to compare, a bigint or lua number.
-- @param y Right value to compare, a bigint or lua number.
-- @see bigint.ult
function bigint.__lt(x, y)
  local ix = bigint.convert(x)
  local iy = bigint.convert(y)
  if ix and iy then
    local xneg, yneg = ix:isneg(), iy:isneg()
    if xneg == yneg then
      return bigint.ult(ix, iy)
    else
      return xneg and not yneg
    end
  else
    return bigint.tonumber(x) < bigint.tonumber(y)
  end
end

--- Compare if number x is less or equal than y considering bigints and signs.
-- @param x Left value to compare, a bigint or lua number.
-- @param y Right value to compare, a bigint or lua number.
-- @see bigint.ule
function bigint.__le(x, y)
  local ix = bigint.convert(x)
  local iy = bigint.convert(y)
  if ix and iy then
    local xneg, yneg = ix:isneg(), iy:isneg()
    if xneg == yneg then
      return bigint.ule(ix, iy)
    else
      return xneg and not yneg
    end
  else
    return bigint.tonumber(x) <= bigint.tonumber(y)
  end
end

--- Convert a bigint to a string on base 10.
-- @see bigint.tobase
function bigint:__tostring()
  return self:tobase(10)
end

setmetatable(bigint, {
  __call = function(_, x)
    return bigint.new(x)
  end
})

-- set default scale
bigint.scale(256)

return bigint
