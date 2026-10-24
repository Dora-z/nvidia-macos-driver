#!/usr/bin/env python3
"""Replay setDetailedTimings with macOS's list for a 1080p 50/60/100/120/144/180/200 Hz panel: HiDPI desktops on the
fast rates sit past entry 64 and are kept only under nvfbscalehz. An optional argument is a file of raw 160-byte
IODetailedTimingInformationV2 records (macOS's IOFBDetailedTimings) to replay instead of the synthetic list."""
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'kexts/NVRMFB/fb/nvrm-fb.cpp').read_text()
start = source.index('// The order setDetailedTimings keeps macOS')
method = source[start:source.index('void NVRMNVDAFramebuffer::publishTimingCaps(', start)]
fixture = r'''
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
using NvU32=uint32_t;using UInt64=uint64_t;using UInt32=uint32_t;using IODisplayModeID=int32_t;
#define FBLOG(...) ((void)0)
#define kIOFBDetailedTimingsKey "IOFBDetailedTimings"
static const IODisplayModeID kModeId = 1;
static void nvu_copy(void *d,const void *s,size_t n){memcpy(d,s,n);}
static uint32_t gHz=0;
static bool PE_parse_boot_argn(const char *name,void *out,int){
    if(!gHz||strcmp(name,"nvfbscalehz"))return false;*(uint32_t *)out=gHz;return true;
}
struct IODetailedTimingInformationV2 {   // the 160-byte layout from IOGraphicsTypes.h
    UInt32 detailedTimingModeID,r1,r2,horizontalScaledInset,verticalScaledInset,scalerFlags,horizontalScaled,verticalScaled;
    UInt32 signalConfig,signalLevels;UInt64 pixelClock,minPixelClock,maxPixelClock;
    UInt32 horizontalActive,horizontalBlanking,horizontalSyncOffset,horizontalSyncPulseWidth;
    UInt32 verticalActive,verticalBlanking,verticalSyncOffset,verticalSyncPulseWidth;
    UInt32 rest[16];
};
static_assert(sizeof(IODetailedTimingInformationV2)==160,"layout");
struct OSObject { virtual ~OSObject(){} };
struct OSData : OSObject { std::vector<uint8_t> b; unsigned getLength() const {return (unsigned)b.size();} const void *getBytesNoCopy() const {return b.data();} };
struct OSArray : OSObject { std::vector<OSObject *> v; unsigned getCount() const {return (unsigned)v.size();} OSObject *getObject(unsigned i) const {return v[i];} };
template<class T> static T *dyn(OSObject *o){return dynamic_cast<T *>(o);}
#define OSDynamicCast(T,o) dyn<T>(o)
enum { kIOReturnSuccess=0 };
typedef int IOReturn;
struct NvKmsKapiDisplayModeTimings { NvU32 refreshRate; };
struct NvKmsKapiDisplayMode { NvKmsKapiDisplayModeTimings timings; };
struct NVRMNVDAFramebuffer {
    enum { kMacTimings = 224 };
    IODetailedTimingInformationV2 fDT[256]; unsigned fNDT=0; bool fBootInDT=false; IODisplayModeID fCurId=kModeId;
    NvKmsKapiDisplayMode fBootMode={{60000}}; NvU32 fBootW=1920,fBootH=1080; unsigned fIndex=0,fEdidHits=0;
    unsigned addKmsRefreshModes(unsigned n){return n;}
    int dtIndex(IODisplayModeID id) const {for(unsigned i=0;i<fNDT;i++)if((IODisplayModeID)fDT[i].detailedTimingModeID==id)return (int)i;return -1;}
    void setProperty(const char *,OSArray *){} void setProperty(const char *,unsigned long long,unsigned){} void removeProperty(const char *){}
    IOReturn setDetailedTimings(OSArray *array);
};
static unsigned hzOf(const IODetailedTimingInformationV2 &d){
    UInt64 t=(UInt64)(d.horizontalActive+d.horizontalBlanking)*(d.verticalActive+d.verticalBlanking);return t?(unsigned)((d.pixelClock+t/2)/t):0;}
static OSData *timing(unsigned id,unsigned hz,unsigned sw,unsigned sh){
    IODetailedTimingInformationV2 d={};d.detailedTimingModeID=id;d.horizontalActive=1920;d.verticalActive=1080;
    d.horizontalBlanking=280;d.verticalBlanking=45;d.horizontalScaled=sw;d.verticalScaled=sh;d.pixelClock=(UInt64)2200*1125*hz;
    OSData *o=new OSData;o->b.resize(sizeof d);memcpy(o->b.data(),&d,sizeof d);return o;}
'''
checks = r'''
static unsigned countAt(NVRMNVDAFramebuffer &f,unsigned hz,bool scaled){
    unsigned c=0;for(unsigned i=0;i<f.fNDT;i++)if(hzOf(f.fDT[i])==hz&&(f.fDT[i].horizontalScaled!=0)==scaled)c++;return c;}
int main(int argc,char **argv) {
    OSArray a;unsigned id=0x80001000;
    if(argc>1){
        FILE *fp=fopen(argv[1],"rb");assert(fp);uint8_t rec[160];
        while(fread(rec,1,160,fp)==160){OSData *o=new OSData;o->b.assign(rec,rec+160);a.v.push_back(o);}
        fclose(fp);
    } else {
        // macOS's order: 17 unscaled timings, then the 60 Hz scaled desktops, then each faster rate's 58
        for(unsigned i=0;i<17;i++)a.v.push_back(timing(id++,60,0,0));
        for(unsigned i=0;i<114;i++)a.v.push_back(timing(id++,60,1200+i,675));
        for(unsigned hz: {50u,100u,120u,144u,180u,200u})for(unsigned i=0;i<58;i++)a.v.push_back(timing(id++,hz,1200+i,675));
        a.v.push_back(new OSObject);   // malformed entry
    }
    NVRMNVDAFramebuffer off;gHz=0;off.setDetailedTimings(&a);
    assert(off.fNDT==64 && countAt(off,180,true)==0);
    for(unsigned i=0;i<64;i++)assert(off.fDT[i].detailedTimingModeID==((const IODetailedTimingInformationV2 *)((OSData *)a.v[i])->getBytesNoCopy())->detailedTimingModeID);
    NVRMNVDAFramebuffer on;gHz=180;on.setDetailedTimings(&a);
    const unsigned plain=countAt(on,60,false)+countAt(on,50,false);
    unsigned offered180=0;for(auto *o:a.v){auto *d=dynamic_cast<OSData *>(o);if(d&&d->getLength()>=160){auto *t=(const IODetailedTimingInformationV2 *)d->getBytesNoCopy();if(t->horizontalScaled&&hzOf(*t)==180)offered180++;}}
    assert(on.fNDT<=224 && offered180>0 && countAt(on,180,true)==offered180);
    for(unsigned i=0;i<on.fNDT;i++)if(!on.fDT[i].horizontalScaled)assert(i<plain+8);   // unscaled first
    for(unsigned i=0;i<on.fNDT;i++)for(unsigned j=i+1;j<on.fNDT;j++)assert(on.fDT[i].detailedTimingModeID!=on.fDT[j].detailedTimingModeID);
    assert(on.fBootInDT && hzOf(on.fDT[on.dtIndex(on.fCurId)])==60 && !on.fDT[on.dtIndex(on.fCurId)].horizontalScaled);
    printf("PASS: %u offered; off keeps macOS's first 64 (0 at 180 Hz); nvfbscalehz=180 keeps %u, all %u scaled 180 Hz desktops, unscaled first, no duplicates, boot raster still current\n",
           a.getCount(),on.fNDT,offered180);
}
'''
with tempfile.TemporaryDirectory() as directory:
    path = pathlib.Path(directory)
    (path / 'test.cpp').write_text(fixture + method + checks)
    subprocess.run(['clang++', '-std=c++17', str(path / 'test.cpp'), '-o', str(path / 'test')], check=True)
    subprocess.run([str(path / 'test')] + sys.argv[1:], check=True)
