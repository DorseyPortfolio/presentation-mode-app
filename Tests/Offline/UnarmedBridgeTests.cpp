#include "DeckLinkBridge.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
int main() {
    for(int i=0;i<20;++i) {
        auto* s=pm_decklink_session_create();char error[1024]{};
        assert(pm_decklink_session_status(s,error,sizeof(error))==0);
        PMDeckLinkRoute direct{"test-output","Direct",0,false,5000};
        assert(pm_decklink_session_configure(s,&direct,1,error,sizeof(error))==0);
        PMDeckLinkRoute invalid[]{direct,direct};
        assert(pm_decklink_session_configure(s,invalid,2,error,sizeof(error))<0);
        assert(pm_decklink_session_configure(s,nullptr,0,error,sizeof(error))<0);
        assert(pm_decklink_session_status(s,error,sizeof(error))==0);
        assert(pm_decklink_session_start(s,error,sizeof(error))<0);
        assert(std::strstr(error,"Offline test build"));
        assert(pm_decklink_session_stop(s,error,sizeof(error))==0);
        pm_decklink_session_destroy(s);
    }
    std::cout<<"PASS: 20 unarmed session lifecycles; no device enumeration or output calls\n";
}
