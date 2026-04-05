@0xdeadbeefcafe0001;

struct VehicleSpeed {
  speedKmh     @0 :Float32;  # km/h, IEEE 754
  timestamp    @1 :UInt64;   # microseconds since epoch
  sensorId     @2 :UInt16;
  qualityFlag  @3 :UInt8;
  reserved     @4 :UInt8;    # future use
}
