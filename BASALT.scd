(
Window.closeAll;

s.waitForBoot {

    // Initialization

    var win, multislider, xyslider, keyboard;
    var backgroundImage, backgroundView;

    var xydata = FluidDataSet(s);
    var paramsdata = FluidDataSet(s);
    var xybuf = Buffer.alloc(s, 2);
    var paramsbuf = Buffer.alloc(s, 10);

    var counter = 0;
    var predicting = false;

    var mlp, effectsBus, effectsSynth;

    var voices = IdentityDictionary.new;
    var noteOn, noteOff;
    var keyboardNote = nil;

    var keyboardOctave = 0;
    var keyboardWidth = 1010;
    var whiteKeyCount = 21;
    var whiteWidth = keyboardWidth / whiteKeyCount;
    var blackWidth = whiteWidth * 0.6;
    var blackHeight = 95;

    var whiteDegrees = [0, 2, 4, 5, 7, 9, 11];
    var blackDegrees = [1, 3, 6, 8, 10];
    var blackPositions = [0, 1, 3, 4, 5];

    var parameterNames = [
        "Morph",
        "Grit",
        "Tone",
        "Sweep",
        "Motion",
        "Space",
        "Attack",
        "Decay",
        "Sustain",
        "Release"
    ];

    var projectPath = PathName(thisProcess.nowExecutingPath).pathOnly;

    var backgroundPath = projectPath ++ "BASALT.jpg";
    var xydataPath = projectPath ++ "xydata_basalt.json";
    var paramsdataPath = projectPath ++ "paramsdata_basalt.json";
    var mlpPath = projectPath ++ "mlp_basalt.json";


    // Machine Learning

    mlp = FluidMLPRegressor(
        s,
        [7],
        activation: FluidMLPRegressor.sigmoid,
        outputActivation: FluidMLPRegressor.sigmoid,
        maxIter: 1000,
        learnRate: 0.1,
        batchSize: 1,
        validation: 0
    );


    // Synthesis Engine

    SynthDef(\basaltSynth, {
        arg out = 0, freq = 440, gate = 1, velocity = 0.8;

        var val = FluidBufToKr.kr(paramsbuf);

        var env, filterEnv, filterAttack, filterProgress;
        var attack, decay, sustain, release;
        var bassDrive, bassCharacter, brightness, movement;

        var osc1, osc2, pulse, sub;
        var subtractive, distorted, bassSignal;
        var detune, pulseWidth, driveAmount, foldAmount;

        var lfo, lfoRate, lfoDepth;
        var cutoff, filterFrequency, resonance;
        var signal;

        val = Lag.kr(val, 0.05);

        // Parameter Mapping

        bassCharacter = val[0];
        bassDrive = val[1];

        brightness = val[2];
        filterAttack = val[3].linexp(0, 1, 0.01, 3);
        movement = val[4];

        attack = val[6].linexp(0, 1, 0.001, 5);
        decay = val[7].linexp(0, 1, 0.01, 5);
        sustain = val[8].linlin(0, 1, 0, 1);
        release = val[9].linexp(0, 1, 0.01, 5);

        // Envelopes and Modulation

        env = EnvGen.kr(
            Env.adsr(attack, decay, sustain, release),
            gate,
            doneAction: 2
        );

        filterEnv = EnvGen.kr(
            Env([0, 1], [filterAttack], \sin)
        );

        lfoRate = movement.linexp(0, 1, 0.02, 20);
        lfoDepth = movement.squared;
        lfo = SinOsc.kr(lfoRate);

        // Oscillators and Distortion

        detune = bassCharacter.squared.linlin(0, 1, 0, 0.006);

        osc1 = Saw.ar(freq * (1 - detune));
        osc2 = Saw.ar(freq * (1 + detune));

        pulseWidth = bassCharacter.linlin(0, 1, 0.5, 0.8);

        pulseWidth = (
            pulseWidth + (lfo * lfoDepth * 0.15)
        ).clip(0.1, 0.9);

        pulse = Pulse.ar(freq, pulseWidth);

        sub = (
            SinOsc.ar(freq * 0.5) * 0.3
        ) + (
            SinOsc.ar(freq) * 0.2
        );

        subtractive = (
            (osc1 * 0.35)
            + (osc2 * 0.35)
            + (pulse * bassCharacter * 0.8)
        );

        driveAmount = bassDrive.linexp(0, 1, 1, 50);

        distorted = (
            subtractive * driveAmount
        ).tanh;

        foldAmount = bassDrive.linlin(0, 1, 1, 10);

        distorted = (
            distorted * foldAmount
        ).fold2(1);

        bassSignal = (
            (distorted * 0.8) + sub
        );

        // Filter

        cutoff = brightness.linexp(0, 1, 100, 15000);

        filterProgress = (
            filterEnv
            * (1 - (lfoDepth * ((lfo + 1) * 0.5)))
        ).clip(0, 1);

        filterFrequency = (
            100 * ((cutoff / 100) ** filterProgress)
        ).clip(100, 15000);

        resonance = brightness.linlin(0, 1, 0.4, 2.8);

        signal = MoogFF.ar(
            bassSignal,
            filterFrequency,
            resonance
        );

        signal = (signal * 1.5).tanh;
        signal = signal ! 2;
        signal = LeakDC.ar(signal);
        signal = signal * env * velocity;

        Out.ar(out, signal);

    }).add;


    // Shared Effects

    SynthDef(\basaltReverb, {
        arg in = 0, out = 0;

        var signal, wet;
        var val = FluidBufToKr.kr(paramsbuf);
        var reverb, mix, room;

        val = Lag.kr(val, 0.1);

        reverb = val[5];

        mix = reverb.linlin(0, 1, 0, 0.5);
        room = reverb.linlin(0, 1, 0.2, 0.95);

        signal = In.ar(in, 2);

        wet = FreeVerb2.ar(
            signal[0],
            signal[1],
            mix,
            room,
            0.5
        );

        wet = Limiter.ar(wet, 0.9, 0.01);

        Out.ar(out, wet);

    }).add;

    s.sync;

    effectsBus = Bus.audio(s, 2);

    effectsSynth = Synth.tail(
        s,
        \basaltReverb,
        [
            \in, effectsBus.index,
            \out, 0
        ]
    );


    // MIDI and Note Handling

    noteOn = {
        arg note, velocity = 100;

        if(voices[note].notNil) {
            voices[note].set(\gate, 0);
        };

        voices[note] = Synth.before(
            effectsSynth,
            \basaltSynth,
            [
                \out, effectsBus.index,
                \freq, note.midicps,
                \velocity, velocity / 127,
                \gate, 1
            ]
        );
    };

    noteOff = {
        arg note;

        if(voices[note].notNil) {
            voices[note].set(\gate, 0);
            voices.removeAt(note);
        };
    };

    MIDIClient.init;
    MIDIIn.connectAll;

    MIDIdef.noteOn(\basaltNoteOn, {
        arg velocity, note, channel, source;

        if(velocity > 0) {
            noteOn.value(note, velocity);
        } {
            noteOff.value(note);
        };
    });

    MIDIdef.noteOff(\basaltNoteOff, {
        arg velocity, note, channel, source;

        noteOff.value(note);
    });


    // Graphical User Interface

    win = Window(
        "BASALT - Neural Bass Synthesizer",
        Rect(10, 10, 1050, 750)
    ).front;

    win.view.background_(Color.gray(0.15));

    // Background Image

    if(File.exists(backgroundPath)) {

        var imageWidth, imageHeight;
        var windowWidth = 1050;
        var windowHeight = 750;
        var scale, scaledWidth, scaledHeight;
        var offsetX, offsetY;

        backgroundImage = Image.open(backgroundPath);

        imageWidth = backgroundImage.width;
        imageHeight = backgroundImage.height;

        scale = max(
            windowWidth / imageWidth,
            windowHeight / imageHeight
        );

        scaledWidth = imageWidth * scale;
        scaledHeight = imageHeight * scale;

        offsetX = (windowWidth - scaledWidth) / 2;
        offsetY = (windowHeight - scaledHeight) / 2;

        backgroundView = UserView(
            win,
            Rect(0, 0, windowWidth, windowHeight)
        );

        backgroundView.drawFunc = {
            backgroundImage.drawInRect(
                Rect(
                    offsetX,
                    offsetY,
                    scaledWidth,
                    scaledHeight
                )
            );
        };

    } {
        "BASALT.jpg was not found in the project folder.".warn;
    };


    // Sound Controls

    StaticText(win, Rect(75, 15, 465, 25))
    .string_("Sound Controls")
    .font_(Font("Helvetica", 16))
    .stringColor_(Color.white)
    .align_(\center);

    multislider = MultiSliderView(
        win,
        Rect(75, 70, 465, 465)
    )
    .elasticMode_(1)
    .isFilled_(1)
    .action_({
        arg ms;

        paramsbuf.setn(0, ms.value);
    })
    .value_(0.5.dup(10));

    paramsbuf.setn(0, 0.5.dup(10));

    10.do {
        arg i;

        StaticText(
            win,
            Rect(75 + (i * 46.5), 540, 46.5, 25)
        )
        .string_(parameterNames[i])
        .font_(Font("Helvetica", 9))
        .stringColor_(Color.white)
        .align_(\center);
    };


    // Sound Explorer

    StaticText(win, Rect(540, 15, 480, 25))
    .string_("Sound Explorer")
    .font_(Font("Helvetica", 16))
    .stringColor_(Color.white)
    .align_(\center);

    StaticText(win, Rect(600, 45, 350, 20))
    .string_("Drone")
    .font_(Font("Helvetica", 10))
    .stringColor_(Color.white)
    .align_(\center);

    xyslider = Slider2D(
        win,
        Rect(650, 70, 250, 250)
    )
    .action_({
        arg view;

        xybuf.setn(0, [view.x, view.y]);

        if(predicting) {
            mlp.predictPoint(xybuf, paramsbuf, {
                paramsbuf.getn(0, 10, {
                    arg prediction;

                    defer {
                        multislider.value_(prediction);
                    };
                });
            });
        };
    });

    StaticText(win, Rect(650, 325, 250, 20))
    .string_("Pluck")
    .font_(Font("Helvetica", 10))
    .stringColor_(Color.white)
    .align_(\center);

    StaticText(win, Rect(590, 180, 55, 20))
    .string_("Clean")
    .font_(Font("Helvetica", 10))
    .stringColor_(Color.white)
    .align_(\center);

    StaticText(win, Rect(905, 180, 55, 20))
    .string_("Dirty")
    .font_(Font("Helvetica", 10))
    .stringColor_(Color.white)
    .align_(\center);


    // Machine Learning Controls

    StaticText(win, Rect(540, 365, 480, 25))
    .string_("Machine Learning")
    .font_(Font("Helvetica", 16))
    .stringColor_(Color.white)
    .align_(\center);

    Button(win, Rect(620, 405, 145, 25))
    .states_([["Add Point"]])
    .action_({
        var id = "point-%".format(counter);

        xydata.addPoint(id, xybuf);
        paramsdata.addPoint(id, paramsbuf);

        counter = counter + 1;

        xydata.print;
        paramsdata.print;
    });

    Button(win, Rect(785, 405, 145, 25))
    .states_([["Train"]])
    .action_({
        mlp.fit(xydata, paramsdata, {
            arg loss;

            loss.postln;
        });
    });

    Button(win, Rect(620, 440, 145, 25))
    .states_([["Save Data"]])
    .action_({
        xydata.write(xydataPath);
        paramsdata.write(paramsdataPath);
    });

	Button(win, Rect(785, 440, 145, 25))
	.states_([["Load Data"]])
	.action_({
    xydata.read(xydataPath);
    paramsdata.read(paramsdataPath);
	});

    Button(win, Rect(620, 475, 145, 25))
    .states_([["Save MLP"]])
    .action_({
        mlp.write(mlpPath);
    });

    Button(win, Rect(785, 475, 145, 25))
    .states_([["Load MLP"]])
    .action_({
        mlp.read(mlpPath);
    });

    Button(win, Rect(620, 510, 310, 25))
    .states_([
        ["Not Predicting"],
        ["Predicting"]
    ])
    .action_({
        arg but;

        predicting = but.value.asBoolean;
    });


    // Piano Keyboard

    StaticText(win, Rect(20, 573, 300, 25))
    .string_("Piano Keyboard")
    .font_(Font("Helvetica", 16))
    .stringColor_(Color.white)
    .align_(\left);

    StaticText(win, Rect(825, 573, 75, 25))
    .string_("Octave")
    .font_(Font("Helvetica", 12))
    .stringColor_(Color.white)
    .align_(\right);

    Button(win, Rect(920, 570, 50, 25))
    .states_([["-"]])
    .action_({
        keyboardOctave = (keyboardOctave - 1).clip(0, 3);
        keyboard.refresh;
    });

    Button(win, Rect(980, 570, 50, 25))
    .states_([["+"]])
    .action_({
        keyboardOctave = (keyboardOctave + 1).clip(0, 3);
        keyboard.refresh;
    });

    keyboard = UserView(
        win,
        Rect(20, 610, keyboardWidth, 130)
    )
    .background_(Color.white);

    keyboard.drawFunc = {

        whiteKeyCount.do {
            arg i;

            var octave = (i / 7).floor;
            var degree = whiteDegrees[i % 7];
            var note = (keyboardOctave * 12) + 12
                + (octave * 12) + degree;
            var x = i * whiteWidth;

            Pen.fillColor = if(keyboardNote == note) {
                Color.gray(0.7)
            } {
                Color.white
            };

            Pen.addRect(Rect(x, 0, whiteWidth, 130));
            Pen.fill;

            Pen.strokeColor = Color.black;
            Pen.addRect(Rect(x, 0, whiteWidth, 130));
            Pen.stroke;
        };

        3.do {
            arg octave;

            blackPositions.do {
                arg degree, i;

                var note = (keyboardOctave * 12) + 12
                    + (octave * 12)
                    + blackDegrees[i];

                var x = ((octave * 7) + degree + 1)
                    * whiteWidth - (blackWidth / 2);

                Pen.fillColor = if(keyboardNote == note) {
                    Color.gray(0.4)
                } {
                    Color.black
                };

                Pen.addRect(Rect(x, 0, blackWidth, blackHeight));
                Pen.fill;
            };
        };
    };

    keyboard.mouseDownAction = {
        arg view, x, y;

        var selectedNote = nil;
        var base = (keyboardOctave * 12) + 12;

        if(y < blackHeight) {
            3.do {
                arg octave;

                blackPositions.do {
                    arg degree, i;

                    var blackX = ((octave * 7) + degree + 1)
                        * whiteWidth - (blackWidth / 2);

                    if(
                        (x >= blackX) &&
                        (x <= (blackX + blackWidth))
                    ) {
                        selectedNote = base
                            + (octave * 12)
                            + blackDegrees[i];
                    };
                };
            };
        };

        if(selectedNote.isNil) {
            var index = (x / whiteWidth).floor.clip(0, 20);
            var octave = (index / 7).floor;
            var degree = whiteDegrees[index % 7];

            selectedNote = base + (octave * 12) + degree;
        };

        keyboardNote = selectedNote;

        noteOn.value(selectedNote, 100);

        keyboard.refresh;
    };

    keyboard.mouseUpAction = {
        arg view, x, y;

        if(keyboardNote.notNil) {
            noteOff.value(keyboardNote);
            keyboardNote = nil;
            keyboard.refresh;
        };
    };


    // Cleanup

    win.onClose_({
        voices.values.do({
            arg voice;

            voice.set(\gate, 0);
        });

        MIDIdef(\basaltNoteOn).free;
        MIDIdef(\basaltNoteOff).free;

        effectsSynth.free;
        effectsBus.free;

        if(backgroundImage.notNil) {
            backgroundImage.free;
        };
    });

};
)