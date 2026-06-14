# A2N20v2 TODO

## High Priority

- [ ] Investigate the timing of bus sampling in `apple_bus.sv` - some IIgs systems have sporadic issues with garbage data, specifically around when the data byte is sampled (likely too soon or too late)
        This problem started when we began denoising the ph1 clock signal which was necessary to get the Mockingboard implementation to pass mbaudit (https://github.com/tomcw/mb-audit)

## Medium Priority

- [ ] Verify all Apple II, //e, and IIgs graphics modes work correctly
- [ ] Test Mockingboard audio output quality
- [ ] Add support for additional virtual slot cards

## Low Priority / Future

- [ ] Improve Super Serial Card compatibility
- [ ] Document button functions (accent/accent reset behavior)
- [ ] Consider migrating proven features from Enhanced version
- [ ] Add scanline effect toggle via button

## Known Issues

- IIgs bus timing may cause sporadic garbage data on some systems (see High Priority)

## Build Status

- Last verified build: 2026-01-16
- Timing: All constraints met
- This is the stable/production version for Tang Nano 20K with IIgs support
