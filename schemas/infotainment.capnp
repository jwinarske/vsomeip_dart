@0xdeadbeefcafe0005;

struct Infotainment {
  trackTitle   @0 :Text;
  artist       @1 :Text;
  albumArt     @2 :Data;     # JPEG thumbnail
  durationMs   @3 :UInt32;
  positionMs   @4 :UInt32;
  isPlaying    @5 :Bool;
}
