// Local-only UI fixture. Uses the installed game's Angular runtime and the actual phone directive.
// node tools/phone-preview.cjs <path-to-angular.js> <output-directory>
const fs = require('node:fs')
const path = require('node:path')
const [angularFile, output] = process.argv.slice(2)
if (!angularFile || !output) throw new Error('Supply Angular runtime and preview output directory')
fs.mkdirSync(output, {recursive: true})
fs.copyFileSync(angularFile, path.join(output, 'angular.js'))
fs.copyFileSync('mod/cargo_earth/ui/modules/apps/CargoEarthPhone/app.js', path.join(output, 'phone.js'))
fs.writeFileSync(path.join(output, 'index.html'), `<!doctype html><html lang="en"><meta charset="utf-8"><title>Cargo Earth phone preview</title>
<style>body{margin:0;background:#e7e3de;font:14px system-ui;color:#25201d}main{display:flex;gap:40px;justify-content:center;padding:32px}.device{width:290px;height:560px;flex-shrink:0}aside{width:230px}aside button{display:block;padding:10px;margin:8px 0;width:100%;cursor:pointer}small{color:#625b55}</style>
<main><div class="device" ng-app="beamng.apps"><cargo-earth-phone></cargo-earth-phone></div><aside><h2>Phone layout check</h2><p>Actual directive, sample data, no game actions.</p><button onclick="fixture('idle')">Idle courier</button><button onclick="fixture('delivery')">Active delivery</button><button onclick="fixture('return')">Return to company yard</button><button onclick="fixture('incoming')">Incoming offer</button><button onclick="fixture('resume')">Resume save</button><button onclick="fixture('choose')">First run: career or free play</button><button onclick="fixture('free')">Free play, offline</button><button onclick="fixture('empty')">No nearby companies</button><small>Default game size: 290 × 560. Use the phone tabs to navigate; Menu opens the big window.</small></aside></main>
<script src="angular.js"></script><script>
angular.module('beamng.apps', []);
var mode='idle';
var company={id:'c1',name:'Central Bohemian Logistics',yard:'Distribution centre',km:2.4,routeKm:12.6,wages:1820,minutes:28,reputation:10,atYard:false,independentPay:2800,independentUnlocked:false};
var shift={company:company.name,phase:'returning',completed:2,total:2,held:1820,atYard:false};
var career={rank:'Courier',nextRank:'Local expert',nextAt:50,completed:32,ruined:1,km:231.5,drivenKm:291.8,debt:450,heldWages:1820,cargo:[{id:'parcel',name:'Parcel deliveries',detail:'12 of 20 deliveries',complete:false}],driverRank:'Professional',driverAt:100,driverUnlocked:false,ledger:[{id:'t3',category:'company wages',amount:1820,balance:12480,date:'2026-11-11 12:40',detail:'Central Bohemian Logistics'},{id:'t2',category:'garage',amount:-600,balance:10660,date:'2026-11-11 12:10',detail:'Repairs'},{id:'t1',category:'delivery',amount:240,balance:11260,date:'2026-11-11 11:58',detail:'Local grocery delivery'}]};
var stop={inZone:false,frac:0,stopS:3,leftS:3};
var active={phase:'toDelivery',kind:'food',pay:240,to:{name:'Dlouhá 12',label:'Customer address',town:'Prague'},from:{name:'Neighbourhood kitchen',town:'Prague'},distM:1400,distRoad:true,etaS:150,leftS:435,minutes:15,stop:stop,orders:[],items:[],arriveM:30,count:1};
function phone(){var s={screen:'offline',mode:'courier',online:false,money:12480,todayEarned:2060,todayCount:6,clock:'13:42',status:'ok',debt:450,storage:{capacity:4,used:0,reserved:0,free:4,boxes:1,kg:0},fuel:{pct:64,rangeKm:410}};if(mode==='delivery') {s.screen='active';s.active=active;s.company=company.name;} if(mode==='return'){s.screen='company';s.company=company.name;} if(mode==='incoming'){s.screen='incoming';s.incoming={kind:'food',orderType:'grocery',from:active.from,to:active.to,items:[{qty:2,name:'Groceries'}],pay:240,km:2.1,pickupKm:0.4,leftS:15,totalS:20,minutes:12,slots:4,cargo:'Groceries'};} if(mode==='choose'){s.screen='choose';s.choice={starter:'Ibishu Pigeon',startMoney:650};} if(mode==='free'){s.freePlay=true;} if(mode==='resume'){s.screen='resume';s.savedCar='Ibishu Pigeon';s.resumeHasLocation=true;} return s;}
function places(){return {started:true,status:'ok',home:{name:'Dlouhá 12',town:'Prague',capacity:3},used:2,homeKm:1.8,atHome:false,addresses:[],companies:mode==='empty'?[]:[company,Object.assign({},company,{id:'c2',name:'Regional Parcel Services',reputation:30,independentUnlocked:true})],shift:mode==='return'?shift:null,discovery:{state:'ready',supportsDepots:true}};}
var settings={mode:'courier',canSwitch:true,items:[{key:'minKm',label:'Shortest delivery',value:1,unit:'km'},{key:'maxKm',label:'Longest delivery',value:20,unit:'km'}],autoReach:true,canPause:true};
var garage={started:true,own:true,car:'Ibishu Pigeon',km:291,condition:0.8,value:24000,repair:600,repairHours:0.3,debt:450,debtShare:0.35,money:12480,sellPrice:20000,spares:[],fleet:{cars:[],unlocked:false,rank:'Professional',at:100}};
window.bngApi={serializeToLua:JSON.stringify,engineLua:function(command,callback){var r=command.indexOf('careerState')>=0?career:command.indexOf('places')>=0?places():command.indexOf('settings')>=0?settings:command.indexOf('garage')>=0?garage:phone();setTimeout(function(){callback(r)},10)}};
window.fixture=function(value){mode=value;var el=document.querySelector('cargo-earth-phone')||document.querySelector('.cep').parentElement;var s=angular.element(el).scope();s.$apply(function(){s.s=phone();s.places=places();});};
</script><script src="phone.js"></script></html>`)
console.log(path.resolve(output, 'index.html'))
