//
//  AudioEngine.m
//  audiotest
//
/*
 The MIT Lisence (MIT)

 Copyright 2019 KIRA Ryouta

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

/*
 * This program uses low-efficient method for measurement.
 */

#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import "CAStreamBasicDescription.h"
#import "AudioEngine.h"

static unsigned const bufferSize = 64;
static Float64 const sampleRate = 48000;
static UInt32 const maxNumWave = 65536;

static AudioEngine *engineLocal = nil;

extern "C" {
    AudioEngine *getAudioEngine()
    {
        if (!engineLocal) {
            engineLocal = [[AudioEngine alloc] init];
        }
        return engineLocal;
    }
}

@implementation AudioEngine
{
    @public
    AudioUnit audioUnit;

    unsigned testCounter;
    BOOL stopIncrement;
    BOOL startIncrement;

    UInt32 x[maxNumWave];
    UInt64 prevHostTime;
    Float64 prevSampleTime;
    pthread_mutex_t mutex;
}

static OSStatus playCallback(void *inRefCon,
                             AudioUnitRenderActionFlags *ioActionFlags,
                             const AudioTimeStamp *inTimeStamp,
                             UInt32 inBusNumber,
                             UInt32 inNumberFrames,
                             AudioBufferList *ioData)
{
    AudioEngine *engine = (__bridge AudioEngine *)inRefCon;
    OSStatus ret = pthread_mutex_trylock(&engine->mutex);
    if (ret == noErr) {
        if (engine->_measurement) {
            if (++engine->testCounter > 4096 && !engine->stopIncrement) {
                engine->startIncrement = YES;
                engine->testCounter = 0;
                engine->_score += 32;
                if (engine->_score > maxNumWave) {
                    engine->_score = maxNumWave;
                }
            }

            // Detect Audio Stuttering
            double timeDiff = inTimeStamp->mSampleTime - engine->prevSampleTime;
            if (engine->startIncrement &&
                engine->prevHostTime > 0 &&
                timeDiff > bufferSize * 1.5)
            {
                if (engine->_score > 0) {
                    engine->_score -= 1;
                }
                engine->stopIncrement = YES;
                engine->testCounter = 0;
            }
        }
        engine->prevHostTime = inTimeStamp->mHostTime;
        engine->prevSampleTime = inTimeStamp->mSampleTime;

        Float32 gain = engine->_sound ? 0.04 : 0;
        for (UInt32 i = 0; i < inNumberFrames; ++i) {
            Float32 y = 0;
            for (UInt32 j = 0; j < engine->_score; ++j) {
                engine->x[j] += (UInt32)((double)(1<<24) / sampleRate * 440 / 8 * (j + 1));
                if (engine->x[j] >= (1<<24)) {
                    engine->x[j] -= (1<<24);
                }
                Float32 w = sin((Float32)engine->x[j] * M_PI * 2 / (Float32)(1<<24)) * gain / (j + 1);
                y += w;
            }
            for (UInt32 j = 0; j < ioData->mNumberBuffers; ++j) {
                Float32 *p = (Float32 *)ioData->mBuffers[j].mData;
                p[i] = y;
            }
        }

        pthread_mutex_unlock(&engine->mutex);
    }
    return noErr;
}

- (id)init
{
    self = [super init];
    if (self) {
        mutex = PTHREAD_MUTEX_INITIALIZER;
    }
#if DEBUG
    NSLog(@"Try with Release Build.");
#warning Try with Release Build.
#endif
    return self;
}

- (void)startEngine
{
    prevHostTime = 0;

    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
    [[AVAudioSession sharedInstance] setPreferredSampleRate:sampleRate error:nil];
    [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:bufferSize / sampleRate error:nil];

    if (!audioUnit) {
        AudioComponentDescription desc;
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_RemoteIO;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;
        desc.componentFlags = 0;
        desc.componentFlagsMask = 0;

        AudioComponent component = AudioComponentFindNext(NULL, &desc);
        AudioComponentInstanceNew(component, &audioUnit);
        CAStreamBasicDescription asbd = CAStreamBasicDescription(sampleRate,
                                                                 2,
                                                                 CAStreamBasicDescription::kPCMFormatFloat32,
                                                                 NO);
        AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, sizeof(AudioStreamBasicDescription));

        AURenderCallbackStruct callback;
        callback.inputProc = playCallback;
        callback.inputProcRefCon = (__bridge void *)self;
        AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &callback, sizeof(AURenderCallbackStruct));
    }

    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    AudioUnitInitialize(audioUnit);
    AudioOutputUnitStart(audioUnit);
}

- (void)stopEngine
{
    AudioOutputUnitStop(audioUnit);
    AudioUnitUninitialize(audioUnit);
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
}

- (void)setMeasurement:(BOOL)measurement
{
    if (measurement) {
        [self start];
    } else {
        [self stop];
    }
}

- (void)start
{
    _score = 0;
    testCounter = 0;
    startIncrement = NO;
    stopIncrement = NO;
    _measurement = YES;
}

- (void)stop
{
    _measurement = NO;
}

@end
