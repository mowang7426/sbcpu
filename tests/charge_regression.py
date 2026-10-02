#!/usr/bin/env python3
"""Compile and execute production C policy/SMC snippets with mock hardware.
No iOS SDK required. Not a substitute for an iOS build or device validation.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
engine = (root/'SBCPUChargeEngine.m').read_text()
smc = (root/'SBCPUChargeSMC.m').read_text()
policy = engine[engine.index('    // Compute both independent requests'):engine.index('\nvoid sb_engine_redecide')]
schedule_fn = engine[engine.index('static NSInteger sb_schedule_stage_for_minute'):engine.index('\nbool sb_engine_load_config')]
policy = policy[:policy.rindex('    engine_unlock();')]
config_code = engine[engine.index('        bool oldManualPowerBlock'):engine.index('        bool scheduleConfigChanged')]
config_fn = '''static bool gManualPowerBlock, gManualChargeBlock;
static void change_config(SBCPUChargeConfig newCfg, int pct) {
 SBCPUChargeConfig oldCfg = gCfg; gCfg = newCfg;
''' + config_code + '}\n'
smc_code = smc[smc.index('static int smc_apply_control'):smc.index('\nbool smc_get_charge_blocked')]
preamble = r'''
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <stdio.h>
#include "SBCPUChargeEngine.h"
#include "SBCPUChargeDayNight.h"
typedef long NSInteger;
typedef bool BOOL;
typedef int IOReturn;
enum {kIOReturnSuccess=0,kIOReturnError=-1,kIOReturnIOError=-2,
SB_RESULT_OK=0,SB_RESULT_IO_ERROR=1,SB_RESULT_NO_EXTERNAL_POWER=2,SB_RESULT_OBC_TAKEN=3};
#define NSLog(...) ((void)0)
#define engine_log(...) ((void)0)
#define usleep(x) ((void)0)
static uint8_t hwC,hwI,ext; static uint32_t reason;
static int failReads,failWrites,rejectWrites,readsAfterWrite,writeCount;
static int gChargeCache=-1,gPowerCache=-1,gLastSMCError;
static IOReturn smc_read_key(uint32_t key,void *out,int32_t *size) {
 if(failReads || (readsAfterWrite && writeCount))return -1;
 if(key=='CH0R'){assert(*size==4);*(uint32_t*)out=reason;return 0;}
 assert(*size==1);*(uint8_t*)out=key=='CH0C'?hwC:key=='CH0I'?hwI:ext;return 0;
}
static IOReturn smc_write_key(uint32_t key,const void *in,uint32_t size){
 (void)size; ++writeCount; if(failWrites)return -1;
 if(!rejectWrites){if(key=='CH0C')hwC=*(const uint8_t*)in;else if(key=='CH0I')hwI=*(const uint8_t*)in;}
 return 0;
}
static bool obc_switch(bool enabled){(void)enabled;return true;}
static bool smc_external_connected(void){return ext!=0;}
'''
state = r'''
static SBCPUChargeConfig gCfg;
static bool gLimitBlocked,gPowerBlockUserReleased,gLimitUsesPowerBlock,gLimitInitialized;
static bool gThermalBlocked,gScheduleBlocked,gOBC;
static SBCPUChargeState gState;
static void decide(int pct,bool wireless){
 bool actualPowerBlock=(hwI&1)!=0,actualChargeBlock=(hwC&1)!=0;
 int powerRead=0;
'''
tests = r'''
}
static void reset(void){
 hwC=hwI=reason=0;ext=1;failReads=failWrites=rejectWrites=readsAfterWrite=writeCount=0;
 gCfg=(SBCPUChargeConfig){.smartChargeEnabled=true,.upperLimit=60,.lowerLimit=55};
 gLimitBlocked=gPowerBlockUserReleased=gLimitUsesPowerBlock=gLimitInitialized=false;
 gThermalBlocked=gScheduleBlocked=gOBC=false;gState=SBCPUChargeStateUnknown;
 gChargeCache=gPowerCache=-1;
}
int main(void){
 assert(sb_charge_is_daytime(7*60+59,8*60,22*60)==false);
 assert(sb_charge_is_daytime(8*60,8*60,22*60)==true);
 assert(sb_charge_is_daytime(21*60+59,8*60,22*60)==true);
 assert(sb_charge_is_daytime(22*60,8*60,22*60)==false);
 assert(sb_charge_is_daytime(23*60,22*60,8*60)==true);
 assert(sb_charge_is_daytime(7*60+59,22*60,8*60)==true);
 assert(sb_charge_is_daytime(8*60,22*60,8*60)==false);
 assert(!sb_charge_day_night_times_valid(480,480));
 assert(sb_charge_day_night_times_valid(480,1320));
 NSInteger target=0;
 assert(sb_schedule_stage_for_minute(true,22*60+30,1*60+30,22*60+29,&target)==2 && target==100);
 assert(sb_schedule_stage_for_minute(true,22*60+30,1*60+30,22*60+30,&target)==1 && target==70);
 assert(sb_schedule_stage_for_minute(true,22*60+30,1*60+30,23*60,&target)==1 && target==70);
 assert(sb_schedule_stage_for_minute(true,22*60+30,1*60+30,1*60+29,&target)==1 && target==70);
 assert(sb_schedule_stage_for_minute(true,22*60+30,1*60+30,1*60+30,&target)==2 && target==100);
 assert(sb_schedule_stage_for_minute(true,22*60+30,1*60+30,14*60,&target)==2 && target==100);
 assert(sb_schedule_stage_for_minute(false,22*60+30,1*60+30,1*60+30,&target)==0);
 reset();decide(60,false);SBCPUChargeConfig edited=gCfg;edited.upperLimit=80;
 change_config(edited,58);decide(58,false);assert(!hwI); // raised limit applies now
 reset();gPowerBlockUserReleased=true;edited=gCfg;edited.upperLimit=59;
 change_config(edited,60);decide(60,false);assert(hwI); // threshold edit rearms
 reset();decide(60,false);edited=gCfg;edited.scheduleEnabled=true;
 change_config(edited,58);decide(58,false);assert(hwI); // unrelated save retains hysteresis
 reset();decide(59,false);assert(!hwI);decide(60,false);assert(hwI);
 ext=0;decide(58,false);assert(hwI);decide(55,false);assert(!hwI);
 reset();decide(60,false);ext=0;decide(52,false);assert(!hwI);
 reset();decide(60,false);gCfg.manualChargeBlock=true;ext=0;decide(52,false);
 assert(!hwI); // manual CH0C no longer skips CH0I release
 ext=1;decide(52,false);assert(hwC);gCfg.manualChargeBlock=false;ext=0;decide(52,false);assert(!hwC);
 reset();hwI=1;ext=0;decide(52,false);assert(!hwI); // restart below lower
 reset();hwI=1;ext=0;decide(58,false);assert(hwI); // restart inside band
 reset();hwI=1;ext=0;gPowerBlockUserReleased=true;decide(65,false);assert(!hwI);
 decide(65,false);assert(!hwI);decide(55,false);assert(!gPowerBlockUserReleased);
 ext=1;decide(60,false);assert(hwI);
 reset();hwI=1;gCfg.smartChargeEnabled=false;ext=0;decide(70,false);assert(!hwI);
 reset();gThermalBlocked=gScheduleBlocked=true;decide(52,false);assert(hwC);
 gScheduleBlocked=false;decide(52,false);assert(hwC);gThermalBlocked=false;decide(52,false);assert(!hwC);
 reset();gCfg.manualPowerBlock=true;decide(52,false);assert(hwI); // explicit manual request still honored
 reset();hwI=1;ext=0;decide(52,true);assert(!hwI); // wireless cannot skip recovery
 reset();hwI=1;ext=0;failWrites=1;decide(52,false);assert(hwI && gState==SBCPUChargeStateError);
 failWrites=0;decide(52,false);assert(!hwI);
 reset();hwC=1;ext=0;assert(smc_set_charge_block(true,false)==0);
 reset();hwI=1;ext=0;reason=2;assert(smc_set_charge_block(true,false)==0 && hwC);
 reset();hwC=1;ext=0;reason=2;assert(smc_set_power_block(true,false)==0 && hwI);
 reset();ext=0;assert(smc_manual_charge_block(true,false)==SB_RESULT_OK && hwC);
 reset();ext=0;assert(smc_manual_power_block(true,false)==SB_RESULT_OK && hwI);
 reset();ext=0;assert(smc_set_charge_block(true,false)==SB_RESULT_NO_EXTERNAL_POWER);
 assert(smc_set_power_block(true,false)==SB_RESULT_NO_EXTERNAL_POWER);
 reset();hwI=1;ext=0;readsAfterWrite=1;
 assert(smc_set_power_block(false,false)==SB_RESULT_IO_ERROR); // read-back failure NEVER succeeds
 reset();hwC=1;rejectWrites=1;assert(smc_set_charge_block(false,false)==SB_RESULT_IO_ERROR);
 reset();hwC=2;assert(smc_set_charge_block(true,false)==SB_RESULT_OBC_TAKEN);
 puts("PASS: production policy and SMC mocked regression scenarios");
}
'''
with tempfile.TemporaryDirectory() as tmp:
    source=Path(tmp)/'regression.c'; binary=Path(tmp)/'regression'
    source.write_text(preamble+smc_code+schedule_fn+state+policy+'}\n'+config_fn+tests[2:])
    subprocess.run(['clang','-std=c11','-Wall','-Wextra','-Werror','-Wno-multichar','-I',str(root),str(source),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True)
