#include "PlayoutCore.hpp"
#include <cassert>
#include <iostream>
#include <map>
#include <tuple>
#include <set>
using namespace pm;
struct Fake : Driver {
    std::array<unsigned,5> counts{};
    std::vector<std::tuple<size_t,int64_t,int64_t>> frames;
    std::vector<std::string> events;
    std::array<Content,5> prepared{};
    std::array<bool,3> playing{};
    int failPrepare=-1, failSchedule=-1, failStart=-1, failBuffered=-1, failRelease=-1;
    bool failClear=false;
    int sourceVersion=1;
    std::array<int,5> versions{};
    bool buffered(size_t i,unsigned& n) override { n=counts[i];return int(i)!=failBuffered; }
    bool prepare(size_t i,Content c) override {prepared[i]=c;versions[i]=sourceVersion;events.push_back("prepare"+std::to_string(i));return int(i)!=failPrepare;}
    bool schedule(size_t i,int64_t t,int64_t d) override {
        events.push_back("schedule"+std::to_string(i));
        if(int(i)==failSchedule) return false;
        ++counts[i];frames.emplace_back(i,t,d);return true;
    }
    bool start(int g) override {events.push_back("start"+std::to_string(g));playing[g]=true;return g!=failStart;}
    bool stop(int g) override {events.push_back("stop"+std::to_string(g));playing[g]=false;return true;}
    bool clear(size_t i) override {events.push_back("clear"+std::to_string(i));return !failClear;}
    void settleClear() override {events.push_back("settle");}
    bool release(size_t i) override {events.push_back("release"+std::to_string(i));counts[i]=0;return int(i)!=failRelease;}
};
void verifyCleanup(const Fake& f) {
    for(auto key:{1,3}) {
        auto c=std::find(f.events.begin(),f.events.end(),"clear"+std::to_string(key));
        auto release=std::find(f.events.begin(),f.events.end(),"release"+std::to_string(key));
        assert(c!=f.events.end() && release>c);
    }
    assert(std::find(f.events.begin(),f.events.end(),"clear4")==f.events.end());
    for(bool b:f.playing) assert(!b);
}
int main() {
    int checks=0;
    { std::set<std::string> ids; for(const auto& r:routes()) ids.insert(r.id);assert(ids.size()==5);assert(!routes()[4].key && routes()[4].duration==1001); ++checks; }
    { uint8_t input[]={2,4,8,0,3,5,7,128,99,99,99,99};uint8_t copy[12]={};opaqueCopy(input,12,copy,12,2,1);assert(copy[0]==2 && copy[3]==255 && copy[7]==255 && input[3]==0 && input[7]==128 && copy[8]==0);solid(copy,12,2,1,true);assert(copy[0]==255 && copy[7]==255 && copy[8]==0);solid(copy,12,2,1,false);assert(copy[0]==0 && copy[3]==255 && copy[4]==0);++checks; }
    { Fake f;Scheduler s;assert(s.tick(f));assert(f.frames.size()==15);assert(f.prepared[1]==Content::whiteKey && f.prepared[3]==Content::whiteKey && f.prepared[4]==Content::picture);assert(s.groups[0].next==3600 && s.groups[1].next==3003 && s.groups[2].next==3003);auto before=f.frames.size();assert(s.tick(f));assert(f.frames.size()==before);++checks; }
    { Fake f;Scheduler s;assert(s.tick(f));f.counts={2,3,2,2,2};assert(s.tick(f));assert(s.groups[0].next==3600 && s.groups[1].next==4004);++checks; }
    { Fake f;Scheduler s;assert(s.tick(f));f.events.clear();assert(s.shutdown(f));verifyCleanup(f);assert(f.events.front()=="stop0");++checks; }
    for(int operation=0;operation<4;++operation) for(int endpoint=0;endpoint<5;++endpoint) {
        Fake f;Scheduler s;
        if(operation==0) f.failPrepare=endpoint;
        if(operation==1) f.failSchedule=endpoint;
        if(operation==2) f.failBuffered=endpoint;
        if(operation==3) f.failStart=endpoint%3;
        assert(!s.tick(f));assert(s.failed);verifyCleanup(f);auto n=f.frames.size();assert(!s.tick(f));assert(f.frames.size()==n);++checks;
    }
    { Fake f;Scheduler s;assert(s.tick(f));f.counts[1]=0;assert(!s.tick(f));verifyCleanup(f);++checks; }
    { Fake f;Scheduler s;assert(s.tick(f));f.counts[0]=1;f.counts[1]=3;assert(!s.tick(f));verifyCleanup(f);++checks; }
    { Fake f;Scheduler s;assert(s.tick(f));f.failClear=true;f.failRelease=3;assert(!s.shutdown(f));assert(s.error.find("cleanup failed")!=std::string::npos);verifyCleanup(f);++checks; }
    // 10 seconds at 250 scheduler ticks/s; source may remain static for the
    // whole run. 50 and 59.94 groups must refill independently without drift.
    { Fake f;Scheduler s;assert(s.tick(f));std::array<int64_t,3> consumed{{0,0,0}};
      for(int64_t now=240;now<=600000;now+=240) {
        for(int g=0;g<3;++g) {
          auto due=now/s.groups[g].duration;
          auto n=due-consumed[g];consumed[g]=due;
          for(auto i:s.groups[g].indices) {assert(f.counts[i]>=n);f.counts[i]-=unsigned(n);}
        }
        assert(s.tick(f));for(auto n:f.counts) assert(n<=3);
      }
      assert(consumed[0]==500 && consumed[1]==599 && consumed[2]==599);
      for(int g=0;g<2;++g) {
        std::vector<std::pair<int64_t,int64_t>> fill,key;
        for(auto [i,t,d]:f.frames) {if(i==s.groups[g].indices[0]) fill.emplace_back(t,d);if(i==s.groups[g].indices[1]) key.emplace_back(t,d);}
        assert(fill==key);for(size_t i=1;i<fill.size();++i) assert(fill[i].first-fill[i-1].first==s.groups[g].duration);
      }
      ++checks;
    }
    std::cout<<"PASS: "<<checks<<" scheduler/pixel cases (including 20 injected failures and 10s mixed-cadence simulation)\n";
}
