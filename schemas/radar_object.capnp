@0xdeadbeefcafe0002;

struct RadarObject {
  objectId     @0 :UInt16;
  distanceM    @1 :Float32;  # meters
  azimuthDeg   @2 :Float32;  # degrees from centerline
  velocityMs   @3 :Float32;  # m/s relative velocity
  rcsDbsm      @4 :Float32;  # radar cross section dBsm
  timestamp    @5 :UInt64;   # microseconds since epoch
  classification @6 :UInt8;  # 0=unknown, 1=car, 2=truck, 3=pedestrian, 4=bike
}
