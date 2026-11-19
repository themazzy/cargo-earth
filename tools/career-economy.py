# Cargo Earth career economy model: net CZK an hour of one typical job of each kind. The pay formulas are copied from
# the Lua modules (keep them in step); distances, speeds and fuel burn are estimates. Run: python3 tools/career-economy.py
# (rules before the 2026-11-18 rebalance) or with --proposal (the rules now in the mod).
import math, sys
P='--proposal' in sys.argv
r5=lambda x: math.floor(x/5+0.5)*5
GAS,DIE=13,12                       # fuel.PRICE
L100={'car':12,'suv':18,'van':16,'rigid':35,'semi':50}   # assumed BeamNG burn, L/100 km
PRICE={'car':GAS,'suv':GAS,'van':DIE,'rigid':DIE,'semi':DIE}
UPK={'car':1,'suv':1.15,'van':1.3,'rigid':2.4,'semi':3.2}
up_km=60/800+300/2500+175/1600       # upkeep.ITEMS per km for a car
def run_cost(t,km,mult=1): return km*(L100[t]/100*PRICE[t]*mult+up_km*UPK[t])
ALLOW={'car':1,'suv':2,'van':3,'rigid':8,'semi':12}
rows=[]
def add(name,unlock,vehicle,pay,minutes,cost,note=''):
    rows.append((name,unlock,vehicle,pay,minutes,cost,(pay-cost)*60/minutes,note))
WAIT=0.5
# food: 3 km straight order, 1.5 km straight ride to restaurant (garage.courierIncome), 30 km/h, 4 min stops
road,ride=3*1.35,1.5*1.35
base=r5(49+16*road); bonus=0.6*0+0.25*40+0.15*80; tip=base*0.25*0.4
add('Food delivery','start','starter car',base+bonus+tip,(road+ride)/30*60+4+WAIT,run_cost('car',road+ride))
# taxi: 5 km straight ride (6.5 road), 1 km straight to the passenger, 30 km/h, 2.5 min boarding
trip,pick=5*1.3,1*1.3
fare=r5(((45+13*trip) if P else (50+18*trip))*1.12*1.125)+r5(trip*ALLOW['car']); fare*=1.10
add('Taxi','start (passenger seat)','starter car',fare,(trip+pick)/30*60+2.5+WAIT,run_cost('car',trip+pick))
# parts run: 15 road km, 7 road km to the supplier, 13 slots, 40 km/h, 5 min
d,p=15,7
add('Parts run','SUV or pickup','used SUV',r5((110+16*d+4*13) if P else (70+10*d+2*13))+r5(d*2),(d+p)/40*60+5+WAIT,run_cost('suv',d+p))
# parcel route: 5 stops, 8 km straight of legs, 4 road km to the depot, 30 km/h, 2 min load + 1.5 min a stop
d,p=8*1.35,4
add('Parcel route','van','used van',r5((120+60*5+10*d) if P else (80+45*5+10*d))+r5(d*3),(d+p)/30*60+2+1.5*5+WAIT,run_cost('van',d+p))
# van freight own: 15 road km, 6.5 road km to the pickup, cargo factor 1.1, 40 km/h, 5 min
d,p=15,6.5
add('Van freight (own van)','van','used van',r5(((150+18*d) if P else (80+11*d))*1.1)+r5(d*3),(d+p)/40*60+5+WAIT,run_cost('van',d+p))
# light tow, borrowed trailer: 6 km to the shop, 13 km shop->car empty (paid 0.5 rate), 13 km back loaded, 40 km/h, 8 min
s,e,l=6,13,13
add('Tow, borrowed trailer','tow hitch','car with hitch',r5(220+14*l+14*(1.0 if P else 0.5)*e),(s+e+l)/40*60+8+WAIT,run_cost('car',s+e+l,1.4))
add('Tow, own car trailer','tow hitch + 2,500 trailer','car with hitch',r5(220+14*l),(4+l)/40*60+5+WAIT,run_cost('car',4+l,1.4))
# bus: 18 stops 0.5 km straight apart (0.625 road), timetable from bus.legMinutes; driven at 28 km/h + 10 s a stop; 6 min to the depot
n,gap=18,0.5*1.25
leg=max(1.5,gap/max(18,min(45,18+8*gap))*60*1.15+0.6); T=n*leg+1
riders=sum(max(1,math.ceil(14*(1-(a-1)/n)))/2 for a in range(1,n)); riders=math.floor(riders+0.5)
bus_pay=(r5((40 if P else 60)+(4.5 if P else 7)*T+3*n)+(1.5 if P else 2)*riders)*(0.6+0.004*90)*0.8   # employment.SHARE
add('City bus line','start (no vehicle)','lent bus',bus_pay,n*gap/28*60+n*10/60+6,0,f'timetable {T:.0f} min')
add('City bus line, on timetable','start','lent bus',bus_pay,T+6,0)
# company contracts (loaner, fuel card): two legs out of one yard, return paid, 80 %; 5 road km to the yard
def company(tier,leg,speed,base,rate,share=0.8,handling=8):
    if P and tier!='van': share=0.65
    pay=2*r5((base+rate*leg)*1.1+rate*leg*1.1)*share
    return pay,(4*leg+5)/speed*60+handling
pay,m=company('van',10,35,*((150,18) if P else (80,11))); add('Company van contract','start','loaner van',pay,m,0)
pay,m=company('rigid',25,50,*((250,22) if P else (120,15))); add('Company box truck contract','5 van hauls','loaner box truck',pay,m,0)
pay,m=company('semi',40,55,300,22,handling=15); add('Company tractor contract','+10 box truck hauls','loaner tractor',pay,m,0)
# own trucks: rigid 40 road km, 10 to the pickup; semi 80 road km, 12 to the pickup
d,p=40,10
add('Box truck freight (own)','5 van hauls','used box truck',r5(((250+22*d) if P else (120+15*d))*1.1)+r5(d*8),(d+p)/50*60+8+WAIT,run_cost('rigid',d+p))
d,p=80,12
semi=r5((300+22*d)*1.1)+r5(d*12)
add('Tractor freight (own, hired trailer)','+10 box truck hauls','used tractor',semi,(d+p)/55*60+12+WAIT,run_cost('semi',d+p))
add('Tractor freight (own, firm trailer)','firm + 6,000 trailer','used tractor',semi*1.12,(d+p)/55*60+12+WAIT,run_cost('semi',d+p))
d=40
fuelrun=math.floor((300+22*d)*(1.15 if P else 1.55)*1.15/50+0.5)*50+r5(16000*0.02)+r5(d*12)
add('Fuel tanker run (own)','+10 box truck hauls','used tractor',fuelrun,(d+p)/55*60+12+WAIT,run_cost('semi',d+p))
for r in rows: print(f'{r[0]:38s} {r[3]:7.0f} {r[4]:6.1f} min  cost {r[5]:5.0f}  net/h {r[6]:6.0f}  {r[7]}')
print('riders',riders,'T',T)
# hired drivers: average driver speed 1.0, care 1.0, wage 15+15+12.5 = 42.5 (+10 truck, +15 artic)
G={'car':70,'suv':90,'van':110,'rigid':170,'semi':260}; KM={'car':8,'suv':10,'van':10,'rigid':12,'semi':15}
IC={'car':250,'suv':300,'van':350,'rigid':700,'semi':1000}; W={'car':42.5,'suv':42.5,'van':42.5,'rigid':52.5,'semi':67.5}
for t in G:
    for office in (1,1.3):
        net=G[t]*office-W[t]-0.03*IC[t]-KM[t]*up_km*UPK[t]
        print(f'driver {t:5s} office x{office}: {net:6.1f}/shift  {net*6:6.0f}/h')
