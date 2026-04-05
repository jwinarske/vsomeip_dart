@0xdeadbeefcafe0003;

struct ImuData {
  accelX       @0 :Float32;  # m/s^2
  accelY       @1 :Float32;
  accelZ       @2 :Float32;
  gyroX        @3 :Float32;  # rad/s
  gyroY        @4 :Float32;
  gyroZ        @5 :Float32;
  timestamp    @6 :UInt64;   # microseconds since epoch
  sensorId     @7 :UInt16;
}
