#include "rtc_packetizer.h"
#include <cassert>
#include <iostream>

int main() {
    auto single = hopp::payloads({{0x65, 1, 2}});
    assert(single.size() == 1 && single[0][0] == 0x65);
    auto stap = hopp::payloads({{0x67, 1}, {0x68, 2}});
    assert(stap.size() == 1 && stap[0] == hopp::Bytes({0x78, 0, 2, 0x67, 1, 0, 2, 0x68, 2}));
    hopp::Bytes big(4000, 42);
    big[0] = 0x65;
    auto fus = hopp::payloads({big});
    hopp::Bytes rebuilt{uint8_t((fus[0][0] & 0xe0) | (fus[0][1] & 31))};
    assert(fus.size() == 4 && (fus.front()[1] & 0x80) && (fus.back()[1] & 0x40));
    for (auto &fu : fus) {
        assert(fu.size() <= 1200 && (fu[0] & 31) == 28);
        rebuilt.insert(rebuilt.end(), fu.begin() + 2, fu.end());
    }
    assert(rebuilt == big);
    assert(hopp::payloads({hopp::Bytes(1200, 0x61)})[0].size() == 1200);
    uint8_t good[] = {0, 0, 0, 2, 0x61, 1};
    assert(hopp::avcc(good, sizeof(good)).size() == 1);
    for (size_t n : {size_t(1), size_t(4), size_t(5)}) {
        bool threw = false;
        try {
            hopp::avcc(good, n);
        } catch (...) {
            threw = true;
        }
        assert(threw);
    }
    auto packet = hopp::rtp({0x65}, 102, 65535, 0xffffffff, 123, true);
    assert(packet[1] == (102 | 128) && packet[2] == 255 && packet[7] == 255);
    std::cout << "single-NAL, STAP-A, FU-A roundtrip, MTU, malformed AVCC, RTP: PASS\n";
}
