# Cargo Earth: local money

Jan's pick on 12 November 2026: money in the currency of the country you drive in, exchanged for free at the border.

## How it works

- The mod bundles simplified country borders (`data/borders.json`, Natural Earth 1:10m, public domain). It works
  offline and everywhere. The borders are accurate to about 500 m, and small islands are left out.
- Every 5 seconds the game checks which country you are in. After two readings in a row in a new country, your money
  switches to that country's currency. A short drive back and forth on a border road changes nothing.
- The exchange is free and uses fixed rates (`currencydata.lua`, an approximate 2025 snapshot; game Lua has no
  internet). The value of your money never changes, only the numbers and the symbol. A message says what you had and
  what it is now. At sea, or in a gap in the borders, the money stays as it was.
- The phone shows every amount, price per litre and message in the local currency. Finances names the currency and
  the country.

## Inside

All amounts are still kept in one base unit (CZK, which saves from before this change already use), so pay, prices,
fees, debt and the ledger keep their balance. A pay of 220 is worth the same in every country. Saves gain two fields,
`country` and `currency`. An old save is shown in the local currency from the first reading on, without a message
about an exchange. Until the country is known, the phone shows euros.

`currency.lua` holds the rules (rates, formatting, the border readings), `borders.lua` finds the country of a point,
and `currencydata.lua` lists the rates, each country's currency, the currency symbols and the country names.

## Not yet verified in game

How long `borders.json` (3.6 MB) takes to load, and how long a lookup in a large country takes in LuaJIT.
