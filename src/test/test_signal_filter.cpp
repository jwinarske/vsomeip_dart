//
//    Copyright (c) 2026 Joel Winarske
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//

#include <cstring>
#include <gtest/gtest.h>

#include "../signal_filter.h"

// ── PassthroughFilter ───────────────────────────────────────────────────────

TEST(PassthroughFilter, ReturnsInputUnchanged) {
    PassthroughFilter f;
    EXPECT_FLOAT_EQ(f.apply(1.0f), 1.0f);
    EXPECT_FLOAT_EQ(f.apply(-3.14f), -3.14f);
    EXPECT_FLOAT_EQ(f.apply(0.0f), 0.0f);
}

// ── EmaFilter ───────────────────────────────────────────────────────────────

TEST(EmaFilter, FirstSampleReturnsInput) {
    EmaFilter f(0.5f);
    EXPECT_FLOAT_EQ(f.apply(10.0f), 10.0f);
}

TEST(EmaFilter, SmoothsTowardSetpoint) {
    EmaFilter f(0.2f);  // alpha = 0.2 → heavy smoothing
    f.apply(0.0f);      // initial
    auto v1 = f.apply(100.0f);
    auto v2 = f.apply(100.0f);
    auto v3 = f.apply(100.0f);
    EXPECT_LT(v1, v2);
    EXPECT_LT(v2, v3);
    EXPECT_LT(v3, 100.0f);  // not yet converged
}

TEST(EmaFilter, AlphaOneIsPassthrough) {
    EmaFilter f(1.0f);
    EXPECT_FLOAT_EQ(f.apply(5.0f), 5.0f);
    EXPECT_FLOAT_EQ(f.apply(-2.0f), -2.0f);
}

TEST(EmaFilter, ResetClearsState) {
    EmaFilter f(0.5f);
    f.apply(100.0f);
    f.reset();
    EXPECT_FLOAT_EQ(f.apply(50.0f), 50.0f);  // first sample again
}

TEST(EmaFilter, ClampsAlphaToValidRange) {
    EmaFilter f1(-1.0f);  // clamped to ~0
    EmaFilter f2(2.0f);   // clamped to 1
    f1.apply(0.0f);
    f2.apply(0.0f);
    // f1: very heavy smoothing, f2: passthrough
    EXPECT_NEAR(f1.apply(100.0f), 0.1f, 1.0f);
    EXPECT_FLOAT_EQ(f2.apply(100.0f), 100.0f);
}

// ── Lowpass1Filter ──────────────────────────────────────────────────────────

TEST(Lowpass1Filter, FirstSampleReturnsInput) {
    Lowpass1Filter f(10.0f, 100.0f);
    EXPECT_FLOAT_EQ(f.apply(50.0f), 50.0f);
}

TEST(Lowpass1Filter, ConvergesToSteadyState) {
    Lowpass1Filter f(5.0f, 100.0f);
    f.apply(0.0f);
    for (int i = 0; i < 200; ++i)
        f.apply(100.0f);
    // Should be close to 100 after many samples
    EXPECT_NEAR(f.apply(100.0f), 100.0f, 0.5f);
}

// ── MedianFilter ────────────────────────────────────────────────────────────

TEST(MedianFilter, RejectsSpikes) {
    MedianFilter f(5);
    f.apply(10.0f);
    f.apply(10.0f);
    f.apply(10.0f);
    f.apply(1000.0f);  // spike
    auto result = f.apply(10.0f);
    EXPECT_FLOAT_EQ(result, 10.0f);  // spike rejected
}

TEST(MedianFilter, WindowSizeOne) {
    MedianFilter f(1);
    EXPECT_FLOAT_EQ(f.apply(5.0f), 5.0f);
    EXPECT_FLOAT_EQ(f.apply(99.0f), 99.0f);
}

// ── FilterRegistry ──────────────────────────────────────────────────────────

TEST(FilterRegistry, EmptyRegistryHasNoFilter) {
    FilterRegistry reg;
    EXPECT_FALSE(reg.has_filter(0x1234, 0x0001, 0x8001));
    EXPECT_EQ(reg.count(), 0u);
}

TEST(FilterRegistry, SetAndHasFilter) {
    FilterRegistry reg;
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 0, 0.5f);
    EXPECT_TRUE(reg.has_filter(0x1234, 0x0001, 0x8001));
    EXPECT_EQ(reg.count(), 1u);
}

TEST(FilterRegistry, ClearFilter) {
    FilterRegistry reg;
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 0, 0.5f);
    reg.clear_filter(0x1234, 0x0001, 0x8001);
    EXPECT_FALSE(reg.has_filter(0x1234, 0x0001, 0x8001));
}

TEST(FilterRegistry, KeyComposition) {
    auto k1 = FilterRegistry::make_key(0x1234, 0x0001, 0x8001);
    auto k2 = FilterRegistry::make_key(0x1234, 0x0001, 0x8002);
    auto k3 = FilterRegistry::make_key(0x1234, 0x0002, 0x8001);
    EXPECT_NE(k1, k2);
    EXPECT_NE(k1, k3);
}

TEST(FilterRegistry, ApplyFiltersFloatInPlace) {
    FilterRegistry reg;
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 0, 1.0f);

    uint8_t payload[4];
    float input = 42.5f;
    std::memcpy(payload, &input, sizeof(float));

    EXPECT_TRUE(reg.apply(0x1234, 0x0001, 0x8001, payload, 4));

    float out;
    std::memcpy(&out, payload, sizeof(float));
    EXPECT_FLOAT_EQ(out, 42.5f);  // alpha=1 = passthrough
}

TEST(FilterRegistry, ApplyEmaSmoothsValue) {
    FilterRegistry reg;
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 0, 0.5f);

    uint8_t payload[4];
    float v;

    v = 10.0f;
    std::memcpy(payload, &v, sizeof(float));
    reg.apply(0x1234, 0x0001, 0x8001, payload, 4);
    std::memcpy(&v, payload, sizeof(float));
    EXPECT_FLOAT_EQ(v, 10.0f);  // first sample

    v = 100.0f;
    std::memcpy(payload, &v, sizeof(float));
    reg.apply(0x1234, 0x0001, 0x8001, payload, 4);
    std::memcpy(&v, payload, sizeof(float));
    EXPECT_FLOAT_EQ(v, 55.0f);  // 0.5 * 100 + 0.5 * 10
}

TEST(FilterRegistry, ApplyAtNonZeroOffset) {
    FilterRegistry reg;
    // Filter the float at byte offset 4 (e.g., after a uint32 header)
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 4, 1.0f);

    uint8_t payload[8] = {0xAA, 0xBB, 0xCC, 0xDD, 0, 0, 0, 0};
    float input = 99.0f;
    std::memcpy(payload + 4, &input, sizeof(float));

    EXPECT_TRUE(reg.apply(0x1234, 0x0001, 0x8001, payload, 8));

    // First 4 bytes unchanged
    EXPECT_EQ(payload[0], 0xAA);
    EXPECT_EQ(payload[3], 0xDD);

    // Filtered float at offset 4
    float out;
    std::memcpy(&out, payload + 4, sizeof(float));
    EXPECT_FLOAT_EQ(out, 99.0f);
}

TEST(FilterRegistry, ApplyOutOfBoundsReturnsFalse) {
    FilterRegistry reg;
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 4, 0.5f);

    uint8_t payload[4] = {};  // only 4 bytes, offset 4 needs 8
    EXPECT_FALSE(reg.apply(0x1234, 0x0001, 0x8001, payload, 4));
}

TEST(FilterRegistry, ApplyMissingFilterReturnsFalse) {
    FilterRegistry reg;
    uint8_t payload[4] = {};
    EXPECT_FALSE(reg.apply(0x9999, 0x0001, 0x8001, payload, 4));
}

TEST(FilterRegistry, ReplacingFilterResetsState) {
    FilterRegistry reg;
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 0, 0.5f);

    uint8_t payload[4];
    float v = 100.0f;
    std::memcpy(payload, &v, sizeof(float));
    reg.apply(0x1234, 0x0001, 0x8001, payload, 4);  // initialize at 100

    // Replace with new filter
    reg.set_filter(0x1234, 0x0001, 0x8001, FilterType::Ema, 0, 0.5f);

    v = 50.0f;
    std::memcpy(payload, &v, sizeof(float));
    reg.apply(0x1234, 0x0001, 0x8001, payload, 4);
    std::memcpy(&v, payload, sizeof(float));
    EXPECT_FLOAT_EQ(v, 50.0f);  // first sample of new filter
}

// ── Multi-filter-per-event tests ────────────────────────────────────────────

TEST(FilterRegistry, MultipleFiltersOnSameEvent) {
    FilterRegistry reg;
    // Same event, three filters at offsets 0, 4, 8 — like an attitude payload
    // [pitch][roll][yaw]
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 1.0f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 4, 1.0f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 8, 1.0f);

    EXPECT_TRUE(reg.has_filter(0x2000, 0x0001, 0x9001));
    EXPECT_EQ(reg.count(), 1u);  // one event, three offsets
}

TEST(FilterRegistry, MultipleFiltersAllApplyIndependently) {
    FilterRegistry reg;
    // Three EMA filters at offsets 0, 4, 8 with alpha=1 (passthrough)
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 1.0f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 4, 1.0f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 8, 1.0f);

    uint8_t payload[16];
    float p = 1.0f, r = 2.0f, y = 3.0f, t = 4.0f;
    std::memcpy(payload + 0, &p, 4);
    std::memcpy(payload + 4, &r, 4);
    std::memcpy(payload + 8, &y, 4);
    std::memcpy(payload + 12, &t, 4);  // throttle - NOT filtered

    EXPECT_TRUE(reg.apply(0x2000, 0x0001, 0x9001, payload, 16));

    // Filtered values should match input (alpha=1 = passthrough first sample)
    float pOut, rOut, yOut, tOut;
    std::memcpy(&pOut, payload + 0, 4);
    std::memcpy(&rOut, payload + 4, 4);
    std::memcpy(&yOut, payload + 8, 4);
    std::memcpy(&tOut, payload + 12, 4);
    EXPECT_FLOAT_EQ(pOut, 1.0f);
    EXPECT_FLOAT_EQ(rOut, 2.0f);
    EXPECT_FLOAT_EQ(yOut, 3.0f);
    EXPECT_FLOAT_EQ(tOut, 4.0f);  // unchanged because no filter
}

TEST(FilterRegistry, MultipleFiltersWithDifferentSmoothingRates) {
    FilterRegistry reg;
    // Pitch heavy, roll medium, yaw light
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 0.1f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 4, 0.5f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 8, 1.0f);

    uint8_t payload[12];

    // First sample — all filters initialize at the input value
    auto pack = [&payload](float p, float r, float y) {
        std::memcpy(payload + 0, &p, 4);
        std::memcpy(payload + 4, &r, 4);
        std::memcpy(payload + 8, &y, 4);
    };
    auto unpack = [&payload](float& p, float& r, float& y) {
        std::memcpy(&p, payload + 0, 4);
        std::memcpy(&r, payload + 4, 4);
        std::memcpy(&y, payload + 8, 4);
    };

    pack(0, 0, 0);
    reg.apply(0x2000, 0x0001, 0x9001, payload, 12);

    // Second sample: jump to 100 — each filter responds at its own rate
    pack(100, 100, 100);
    reg.apply(0x2000, 0x0001, 0x9001, payload, 12);

    float p, r, y;
    unpack(p, r, y);
    // Pitch (alpha 0.1):  0.1*100 + 0.9*0 = 10
    // Roll  (alpha 0.5):  0.5*100 + 0.5*0 = 50
    // Yaw   (alpha 1.0):  1.0*100 + 0.0*0 = 100
    EXPECT_FLOAT_EQ(p, 10.0f);
    EXPECT_FLOAT_EQ(r, 50.0f);
    EXPECT_FLOAT_EQ(y, 100.0f);
}

TEST(FilterRegistry, ReplaceFilterAtOffsetResetsThatOffsetOnly) {
    FilterRegistry reg;
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 0.5f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 4, 0.5f);

    uint8_t payload[8];
    auto pack = [&payload](float a, float b) {
        std::memcpy(payload + 0, &a, 4);
        std::memcpy(payload + 4, &b, 4);
    };

    pack(100, 100);
    reg.apply(0x2000, 0x0001, 0x9001, payload, 8);  // both initialize at 100

    // Replace ONLY the offset 0 filter
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 0.5f);

    pack(50, 50);
    reg.apply(0x2000, 0x0001, 0x9001, payload, 8);

    float a, b;
    std::memcpy(&a, payload + 0, 4);
    std::memcpy(&b, payload + 4, 4);
    EXPECT_FLOAT_EQ(a, 50.0f);  // reset → first sample
    EXPECT_FLOAT_EQ(b, 75.0f);  // 0.5 * 50 + 0.5 * 100 = 75
}

TEST(FilterRegistry, ClearFilterAtRemovesOnlyOneOffset) {
    FilterRegistry reg;
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 0.5f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 4, 0.5f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 8, 0.5f);

    EXPECT_TRUE(reg.has_filter(0x2000, 0x0001, 0x9001));

    // Remove the middle one
    reg.clear_filter_at(0x2000, 0x0001, 0x9001, 4);
    EXPECT_TRUE(reg.has_filter(0x2000, 0x0001, 0x9001));  // still has 0 and 8

    // Remove the rest
    reg.clear_filter_at(0x2000, 0x0001, 0x9001, 0);
    reg.clear_filter_at(0x2000, 0x0001, 0x9001, 8);
    EXPECT_FALSE(reg.has_filter(0x2000, 0x0001, 0x9001));
    EXPECT_EQ(reg.count(), 0u);
}

TEST(FilterRegistry, ClearFilterRemovesAllOffsets) {
    FilterRegistry reg;
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 0.5f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 4, 0.5f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 8, 0.5f);

    reg.clear_filter(0x2000, 0x0001, 0x9001);
    EXPECT_FALSE(reg.has_filter(0x2000, 0x0001, 0x9001));
    EXPECT_EQ(reg.count(), 0u);
}

TEST(FilterRegistry, OutOfRangeOffsetSkippedNotFailed) {
    FilterRegistry reg;
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 0, 1.0f);
    reg.set_filter(0x2000, 0x0001, 0x9001, FilterType::Ema, 100, 1.0f);  // OOR

    uint8_t payload[4];
    float v = 42.0f;
    std::memcpy(payload, &v, 4);

    // Should still apply the in-range filter at offset 0
    EXPECT_TRUE(reg.apply(0x2000, 0x0001, 0x9001, payload, 4));
    std::memcpy(&v, payload, 4);
    EXPECT_FLOAT_EQ(v, 42.0f);
}
