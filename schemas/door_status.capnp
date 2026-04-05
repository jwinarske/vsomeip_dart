@0xdeadbeefcafe0004;

struct DoorStatus {
  doorId       @0 :UInt8;    # 0=FL, 1=FR, 2=RL, 3=RR, 4=trunk, 5=hood
  isOpen       @1 :Bool;
  isLocked     @2 :Bool;
  angleDeg     @3 :Float32;  # opening angle in degrees (0 = closed)
  timestamp    @4 :UInt64;
}
