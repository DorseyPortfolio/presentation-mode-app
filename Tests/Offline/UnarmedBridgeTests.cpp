#include "DeckLinkBridge.h"
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
int main() {
    unsetenv("PRESENTATION_MODE_ENABLE_HARDWARE");
    for(int i=0;i<20;++i) {
        auto* s=pm_decklink_session_create();char error[1024]{};
        assert(pm_decklink_session_status(s,error,sizeof(error))==0);
        assert(pm_decklink_session_start(s,error,sizeof(error))<0);
        assert(std::strstr(error,"not armed"));
        assert(pm_decklink_session_stop(s,error,sizeof(error))==0);
        pm_decklink_session_destroy(s);
    }
    std::cout<<"PASS: 20 unarmed session lifecycles; no device enumeration or output calls\n";
}
