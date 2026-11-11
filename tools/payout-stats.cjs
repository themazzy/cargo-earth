// Reproducible payout analysis using the real Lua rules; no game saves are read or changed.
// FENGARI_PATH may point at an existing Fengari installation.
const fs = require('node:fs')
const path = require('node:path')
const assert = require('node:assert/strict')
const f = require(process.env.FENGARI_PATH || 'fengari')
process.chdir(path.join(__dirname, '..'))
const L = f.lauxlib.luaL_newstate()
f.lualib.luaL_openlibs(L)
const records = []
f.lua.lua_pushjsfunction(L, state => {
  const row = []
  for (let i = 1; i <= f.lua.lua_gettop(state); i++) {
    row.push(f.lua.lua_type(state, i) === f.lua.LUA_TNUMBER ? f.lua.lua_tonumber(state, i) : f.to_jsstring(f.lua.lua_tostring(state, i)))
  }
  records.push(row)
  return 0
})
f.lua.lua_setglobal(L, f.to_luastring('emit'))
function literal(v) {
  if (v === null) return 'nil'
  if (typeof v === 'string') return JSON.stringify(v)
  if (typeof v !== 'object') return String(v)
  if (Array.isArray(v)) return '{' + v.map(literal).join(',') + '}'
  return '{' + Object.entries(v).map(([k, x]) => '[' + literal(k) + ']=' + literal(x)).join(',') + '}'
}
const pack = JSON.parse(fs.readFileSync('mod/cargo_earth/lua/ge/extensions/cargoEarth/data/depots_CZ.json', 'utf8'))
const source = `package.path='mod/cargo_earth/lua/ge/extensions/?.lua;'..package.path
local food=require('cargoEarth/food')
local haul=require('cargoEarth/haul')
local jobs=require('cargoEarth/jobs')
local employment=require('cargoEarth/employment')
local fleet=require('cargoEarth/fleet')
local core=require('cargoEarth/core')
local idx=jobs.index(${literal(pack)})
local rows={{id=1,cargoTypes={'parcel'},capacity=10000},{id=2,cargoTypes={'fluid'},capacity=20000},{id=3,cargoTypes={'dryBulk'},capacity=20000}}
local function freight(tier,id,km,pickup)
  local j={cargo=id,adr=idx.cargo[id].adr==true,km=km,pickupKm=pickup}
  if haul.prepare(j,tier,rows,idx) then return j end
end
-- Model assumptions: average speed includes traffic; extra minutes include stops/parking.
-- Offer wait is separate from the delivery timer, and excluded from tip calculations.
local wait=(core.PHONE.pingMinS+core.PHONE.pingMaxS)/120
for _,road in ipairs({1,2,5,6.75,10.8}) do
 for _,pickup in ipairs({0,0.5,3,5}) do
  for _,kind in ipairs({'Meal','Family meal','Groceries'}) do
   local bonus=kind=='Family meal' and food.FAMILY_BONUS or kind=='Groceries' and food.GROCERY_BONUS or 0
   local pay=food.pay(road)+food.farPickup(pickup)+bonus
   local km=road+pickup*food.ROAD_FACTOR
   local time=km/food.SPEED_KMH*60+1
   local tip=food.tip(pay,time,food.minutes(km))
   emit('courier',kind,road,pickup,pay,tip,time+wait,(pay+tip)*60/(time+wait),food.minutes(km))
  end
 end
end
for _,tier in ipairs({'van','rigid','semi'}) do
 for id,meta in pairs(idx.cargo) do
  local j=freight(tier,id,20,0.5)
  if j then emit('cargo',tier,id,meta.name,meta.pay,j.pay,j.adr and 1 or 0) end
 end
 local distances=tier=='van' and {3,10,20,45} or tier=='rigid' and {12,30,60,125} or {20,50,100,250}
 for _,km in ipairs(distances) do
  for _,id in ipairs({'pallets_general','glassware','car_parts','fuel','gravel'}) do
   local j=freight(tier,id,km,0.5)
   if j then
    local time=(km+0.5*jobs.ROAD_FACTOR)/haul.tiers[tier].speed*60+3+wait
    local loopTime=time+km/haul.tiers[tier].speed*60
    emit('freight',tier,id,km,j.pay,time,j.pay*60/time,loopTime,j.pay*60/loopTime,j.minutes)
   end
  end
 end
end
-- A company manifest returns to its yard after each delivery, including the final one.
for _,km in ipairs({1,3,5,10,20}) do
 local j=freight('van','pallets_general',km,0)
 -- As employment.board: the company also pays the empty km back to the yard.
 local gross=2*(math.floor((j.pay+haul.tiers.van.rate*j.km)/5+0.5)*5)
 local time=(km*4+0.5*jobs.ROAD_FACTOR)/35*60+8
 emit('company','Company van',km,gross,math.floor(gross*employment.SHARE+0.5),time,math.floor(gross*employment.SHARE+0.5)*60/time)
 emit('company','Own van contract',km,gross,gross,time,gross*60/time)
end
for _,city in ipairs({{'Prague',50.0755,14.4378},{'Brno',49.1951,16.6068},{'Ostrava',49.8209,18.2625},{'Mikulov',48.8053,16.6378},{'Jicin',50.4372,15.3516}}) do
 for _,offer in ipairs(employment.board(idx,{lat=city[2],lon=city[3]})) do
  local time=(offer.km+offer.pickupKm*jobs.ROAD_FACTOR)/35*60+8
  emit('board',city[1],offer.id,offer.name,offer.pickupKm,offer.km,offer.gross,offer.wages,time,offer.wages*60/time,offer.gross*60/time)
 end
end
emit('fleet',fleet.NET_PER_SHIFT,fleet.SHIFT_S/60,fleet.HIRE_FEE,fleet.NET_PER_SHIFT*3600/fleet.SHIFT_S,math.ceil(fleet.HIRE_FEE/fleet.NET_PER_SHIFT)*fleet.SHIFT_S/60)
for _,kind in ipairs({'food','parcel'}) do
 for _,condition in ipairs({100,75,50,25,0}) do
  local factor=kind=='food' and 0.6+0.004*condition or condition/100
  emit('condition',kind,condition,condition==0 and 0 or math.floor(1000*factor+0.5))
 end
end
for _,late in ipairs({0,5,10,20,25}) do
 emit('late',late,math.max(core.LATE_FLOOR,1-late*core.LATE_PER_MIN.courier),math.max(core.LATE_FLOOR,1-late*core.LATE_PER_MIN.trucking))
end
emit('constants',food.BASE,food.PER_KM,food.FAMILY_BONUS,food.GROCERY_BONUS,core.BATCH_PAY,employment.SHARE,wait)
`
if (f.lauxlib.luaL_dostring(L, f.to_luastring(source)) !== f.lua.LUA_OK) throw Error(f.to_jsstring(f.lua.lua_tostring(L, -1)))
const groups = {}
for (const [kind, ...values] of records) (groups[kind] ||= []).push(values)
assert.equal(groups.freight.find(r => r[0] === 'van' && r[1] === 'pallets_general' && r[2] === 10)[3], 190)
assert.equal(groups.freight.find(r => r[0] === 'semi' && r[1] === 'fuel' && r[2] === 250)[3], 10340)
const dest = path.resolve('docs/research/payout-statistics-0.3.5')
fs.mkdirSync(dest, {recursive:true})
fs.writeFileSync(path.join(dest,'statistics.json'),JSON.stringify({version:'0.3.5',assumptions:{courierSpeedKmh:24,freightSpeedKmh:{van:40,rigid:50,semi:55},companySpeedKmh:35,pickupStraightKm:0.5,courierHandlingMinutes:1,freightHandlingMinutes:3,companyHandlingMinutes:8,averageOfferWaitSeconds:19,notes:'Clean/on-time, no repair expense or debt repayment deducted. One-way freight does not include mandatory return; loop columns add return. Company routes always return.'},groups},null,2))
const headers = {
 courier:['type','delivery_road_km','pickup_straight_km','base_and_bonus_czk','tip_czk','model_minutes','czk_per_hour','deadline_minutes'],
 cargo:['tier','cargo_id','cargo_name','cargo_multiplier','pay_at_20_road_km_czk','adr'],
 freight:['tier','cargo_id','delivery_road_km','pay_czk','one_way_minutes','one_way_czk_per_hour','return_loop_minutes','return_loop_czk_per_hour','deadline_minutes'],
 company:['type','each_delivery_road_km','total_customer_revenue_czk','driver_payout_czk','full_shift_minutes','czk_per_hour'],
 board:['city','company_id','company_name','initial_pickup_straight_km','delivery_plus_return_road_km','total_customer_revenue_czk','driver_payout_czk','full_shift_minutes','czk_per_hour','independent_czk_per_hour'],
 fleet:['net_czk_per_shift','shift_minutes','hire_fee_czk','czk_per_hour','fee_recovery_active_minutes'],
 condition:['kind','condition_percent','pay_on_1000_czk_order'], late:['minutes_late','courier_pay_factor','freight_pay_factor'],
 constants:['courier_base_czk','courier_per_road_km_czk','family_bonus_czk','grocery_bonus_czk','batch_base_multiplier','company_share','offer_wait_minutes']
}
for (const [kind, rows] of Object.entries(groups)) {
 fs.writeFileSync(path.join(dest,kind+'.csv'),[headers[kind],...rows].map(row=>row.map(v=>typeof v==='string'?'"'+v.replaceAll('"','""')+'"':v).join(',')).join('\n')+'\n')
}
const n=v=>Number(v.toFixed(1)).toLocaleString('en-US')
const money=v=>Math.round(v).toLocaleString('en-US')
const table=(head,rows)=>'| '+head.join(' | ')+' |\n| '+head.map(()=>'---').join(' | ')+' |\n'+rows.map(r=>'| '+r.join(' | ')+' |').join('\n')
const short=groups.courier.filter(r=>r[2]===0.5&&[2,6.75].includes(r[1]))
const general=groups.freight.filter(r=>r[1]==='pallets_general'&&[10,30,50].includes(r[2]))
const fuel=groups.freight.filter(r=>r[0]==='semi'&&r[1]==='fuel')
const board=groups.board, rates=board.map(r=>r[8]).sort((a,b)=>a-b)
const body=`# Payout statistics for Cargo Earth 0.3.5

Calculated from the real Lua modules and bundled Czech cargo/depot pack. Reproduce with \`node tools/payout-stats.cjs\` (Fengari dependency or FENGARI_PATH). No game save was read or modified. These are formula-based scenarios, not measured driving results.

## Findings

- Biggest supported native-freight payout: a 250 road km fuel haul pays **${money(groups.freight.find(r=>r[0]==='semi'&&r[1]==='fuel'&&r[2]===250)[3])} CZK** before damage/late/repair/debt effects. Fuel requires articulated-truck progression, tanker/ADR-compatible jobs and suitable endpoints. This is an eligible formula example, not a guarantee a matching route appears at your location.
- Best modeled short-session courier work: nearby groceries, then family meals, then standard meals. The fixed 80/40 CZK size bonuses favour short routes. Groceries need four free slots in one box and helper-discovered stores; family meals need two.
- Since 0.3.5 the company also pays the empty drive back to the yard after each delivery, and the driver keeps 80%. Twenty-five actual generated company offers at five Czech locations model at **${money(rates[0])}–${money(rates.at(-1))} CZK/h**, median **${money(rates[12])} CZK/h**. Company work now pays close to courier work, with repairs covered.
- Independent company contracts pay **25% more** than the same company-van manifest before personal repair expenses, but retain the same backtracking. Regular freight generally uses time better if a useful next job exists near its destination.
- The largest catalog multipliers are not all usable: heavy machinery is 1.8× and LPG 1.65× plus ADR, but the current native allocator does not support those cargo IDs. Do not rank them as presently playable native jobs.

## Modeling assumptions

Courier average: 24 km/h; van 40, rigid 50 and articulated 55 km/h; company routes 35 km/h. Initial pickup is 0.5 straight km, expanded to road distance using the relevant Lua factor (food 1.35, freight 1.3). Extra handling: 1 minute per courier order, 3 minutes per ordinary freight job and 8 minutes per two-job company shift. Ordinary jobs also include 19 seconds average offer wait, excluding it from tip timing. These handling/wait values are modeling assumptions, not fixed in-game loading timers. Setup, vehicle acquisition, searching/declining offers, detours, coupling delays beyond the allowance, repairs and debt repayment are excluded. Company examples include every required return and wages are unavailable until the shift ends.

Use the hourly figures as clean-run comparisons. Ordinary freight one-way rates assume another useful nearby pickup; the return-loop column shows the result if you must drive empty all the way back. Company return travel is already included. Displayed deadlines include slack and are not predicted completion times. No fixed fuel-per-km expense is implemented in the inspected payment code; do not confuse these rates with a complete simulated operating-profit model.

## Short courier work

${table(['Order','Delivery road km','Payout incl. modeled tip, CZK','Modeled minutes','CZK/h'],short.map(r=>[r[0],n(r[1]),money(r[3]+r[4]),n(r[5]),money(r[6])]))}

Near-identical pickup, destination and driving time make groceries about twice the standard-meal pay at 2 road km. Moving from 2 to 6.75 road km increases the payout but lowers the modeled hourly return. Pickup kilometres below 3 straight km receive no extra pay. Beyond 3 km, only 8 CZK per additional straight kilometre is added, rounded to 5 CZK; avoid long pickup drives unless you also want to relocate.

## Ordinary freight

${table(['Vehicle / cargo','Delivery road km','Payout, CZK','One-way minutes','One-way CZK/h','With empty return CZK/h'],[...general,...fuel].map(r=>[r[0]+' / '+r[1],n(r[2]),money(r[3]),n(r[4]),money(r[5]),money(r[7])]))}

Since 0.3.5 articulated trucks have a 300 CZK base and 22 CZK/km, rigid trucks 120 CZK and 15 CZK/km, vans 80 CZK and 11 CZK/km. Short fuel runs remain the best paid work because of fuel's pay factor and the ADR bonus. Rigid unlocks after 5 van hauls; articulated unlocks after a further 10 rigid hauls. The existing loaner system can provide the appropriate vehicle. Reliable endpoints and compatible trailers still constrain availability.

## Company shifts

Each example has two equally long deliveries from the same yard, with both returns included. Initial approach is 0.5 straight km.

${table(['Contract','Each loaded leg, road km','Full-shift payout, CZK','Full-shift minutes','CZK/h'],groups.company.map(r=>[r[0],n(r[1]),money(r[3]),n(r[4]),money(r[5])]))}

The shortest company model (two 1 km deliveries) returns ${money(groups.company[0][3])} CZK in ${n(groups.company[0][4])} minutes. A ten-minute session is therefore better suited to short courier work than a company shift. The generated board sample below has substantially longer routes; do not mistake the synthetic minimum for the typical available contract.

### Actual generated board sample

Fixed city-centre positions: Prague, Brno, Ostrava, Mikulov and Jicin; deterministic board generation; first five displayed offers per position. Payouts and endpoints come from the supplied pack, while times remain modeled.

${table(['Location','Offers','Min–max full-shift payout, CZK','Min–max modeled minutes','Min–max CZK/h'],[...new Set(board.map(r=>r[0]))].map(city=>{const r=board.filter(x=>x[0]===city);return [city,r.length,money(Math.min(...r.map(x=>x[6])))+'–'+money(Math.max(...r.map(x=>x[6]))),n(Math.min(...r.map(x=>x[7])))+'–'+n(Math.max(...r.map(x=>x[7]))),money(Math.min(...r.map(x=>x[8])))+'–'+money(Math.max(...r.map(x=>x[8]))) ]}))}

## Cargo ranking at equal distance

Multipliers are comparisons within a vehicle tier, not across different vehicles. All supported parcel cargo is available to the van allocator: glassware 1.45×, electronics 1.40×, car parts 1.20×, furniture/beer 1.10×, consumer goods/dry food 1.05×, general pallets 1.00×, bricks 0.95×. Glassware/electronics have fragile handling. Car parts pay more than general goods and use sturdy handling. Supported bulk gravel/sand are lowest at 0.75×. Supported fuel is 1.55× plus 15% ADR = **1.7825×**; chemicals are **1.725×**. Ordinary helper-only geography currently supplies general goods, so these richer cargo choices depend on the depot pack and available endpoints.

Current limitation: fluid/bulk cargo condition is not tracked by the parcel-damage rules. Fuel's current high income is therefore not balanced by a corresponding fluid-cargo crash penalty, though vehicle damage/repair costs still exist. That is a balance gap, not evidence of safer cargo.

## Batching, tips and risk

Second courier orders receive 85% of their base/far-pickup payment, rounded to 5 CZK; the full family/grocery size bonus is preserved. A close extra stop can improve income, but both order timers keep running. The discount does not guarantee better hourly pay if the second route adds a long detour.

Tips can reach 25% only at an instantaneous theoretical delivery. They decrease to zero at 70% of the allowed time. The baseline city-speed examples above have zero modeled tips; do not add a flat 25% to every quote.

${table(['Cargo condition','Food base pay on 1,000 CZK order','Parcel pay on 1,000 CZK order'],[100,75,50,25,0].map(c=>[c+'%',groups.condition.find(r=>r[0]==='food'&&r[1]===c)[2],groups.condition.find(r=>r[0]==='parcel'&&r[1]===c)[2]]))}

At zero condition, the load fails and earns nothing, despite food's nonzero formula floor before failure. Food tips also scale with remaining condition. Lateness takes 5% of food pay or 2% of freight pay per minute, with a 50% lateness floor. It combines multiplicatively with condition penalties. Company wages are then 65% of the adjusted delivery revenue. Existing debt can divert up to 50% of earnings to repayment; that is debt reduction, not lost value.

## Drivers and session length

Each driver earns **45 CZK per 10 active minutes**, or **270 CZK per active hour**, alongside your driving. Hiring costs 350 CZK; cash payments recover that fee after eight shifts (**80 active minutes**), excluding the cost of the extra owned car. Hiring unlocks at 30 completed deliveries. A home with capacity three leaves room for at most two parked driver cars while you use another. In company work, fleet advancement currently runs on the temporary company garage, so personal parked drivers do not earn during that borrowed-van shift. Paused, closed-game and parts-preview time does not count.

- **About 10 minutes:** short grocery/family deliveries near your car; standard meals if using the starter bag.
- **15–45 minutes:** clustered courier jobs; a nearby regular van/rigid haul or short articulated run once unlocked. Accept a company shift only after checking its full return distance.
- **An hour or more:** short/mid-distance articulated freight gives strong modeled earnings; long routes favour one large payout and travelling elsewhere, rather than maximum income per minute.
- **Several active hours:** combine eligible fleet drivers with your own paid work. Company shifts pay close to courier work and build employer reputation.

0.3.5 rebalanced trucking (about 1,250-1,700 CZK/h for general semi freight instead of 3,500+) and company contracts (return km paid, 80% share). CSV files and statistics.json retain all 215 calculated rows for inspection.
`
fs.writeFileSync(path.join(dest,'README.md'),body)
console.log('Wrote '+records.length+' payout rows to '+dest)
console.log(JSON.stringify({courier:groups.courier.filter(r=>r[2]===0.5&&[2,6.75].includes(r[1])),company:groups.company.filter(r=>[3,10].includes(r[1])),freight:groups.freight.filter(r=>r[1]==='pallets_general'&&[10,30,50].includes(r[2])),fleet:groups.fleet,board:groups.board.map(r=>[r[0],r[6],r[7],r[8]])},null,2))
