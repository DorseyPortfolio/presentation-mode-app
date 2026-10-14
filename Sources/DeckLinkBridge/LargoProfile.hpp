#pragma once
#include "PlayoutCore.hpp"
namespace pm {
inline const std::vector<Route>& routes() {
    static const std::vector<Route> r{
        {"00000000254a3ad3:3", "Side fill / Top Card (4)", 0, false, 2400},
        {"00000000254a3ad1:1", "Side key / Top Card (2)", 0, true, 2400},
        {"0000000002cf3ad0:0", "LED fill / Bottom Card (1)", 1, false, 2002},
        {"0000000002cf3ad3:3", "LED key / Bottom Card (4)", 1, true, 2002},
        {"0000000002cf3ad1:1", "Confidence / Bottom Card (2)", 2, false, 2002}
    };
    return r;
}
}
