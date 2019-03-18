//
//  ViewController.m
//  audiotest
//
/*
 The MIT Lisence (MIT)

 Copyright 2019 KIRA Ryouta

 Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#import <sys/sysctl.h>
#import <sys/types.h>
#import <sys/param.h>
#import <sys/mount.h>
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <mach/mach_host.h>
#import "AudioEngine.h"
#import "ViewController.h"

static double const fps = 60;

@interface ViewController ()

@end

@implementation ViewController
{
    NSLock *cpuUsageLock;
    unsigned numCPUs;
    processor_cpu_load_info_t cpuInfo, prevCPUInfo;
    mach_msg_type_number_t numCPUInfo, numPrevCPUInfo;
    integer_t *inUse, *user, *system, *nice, *idle, *total;
    unsigned highLoadCount;
    unsigned cpuCheck;
    UInt32 prevScore;
    UInt32 remain;

    IBOutlet UILabel *loadLabel;
    IBOutlet UILabel *scoreLabel;
    IBOutlet UIButton *benchButton;
    IBOutlet UILabel *remainLabel;
    IBOutlet UISlider *scoreSlider;

    CADisplayLink *displayLink;

    AudioEngine * __weak engine;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self) {
        cpuUsageLock = [[NSLock alloc] init];
        int mib[2U] = { CTL_HW, HW_NCPU };
        size_t sizeOfNumCPUs = sizeof(numCPUs);
        int status = sysctl(mib, 2U, &numCPUs, &sizeOfNumCPUs, NULL, 0U);
        if(status)
            numCPUs = 1;
        inUse = malloc(sizeof(integer_t) * numCPUs);
        user = malloc(sizeof(integer_t) * numCPUs);
        system = malloc(sizeof(integer_t) * numCPUs);
        nice = malloc(sizeof(integer_t) * numCPUs);
        idle = malloc(sizeof(integer_t) * numCPUs);
        total = malloc(sizeof(integer_t) * numCPUs);

        engine = getAudioEngine();
    }
    return self;
}

NS_INLINE void mem_free(void *v)
{
    if (v) {
        free(v);
    }
}

- (void)dealloc
{
    mem_free(inUse);
    mem_free(user);
    mem_free(system);
    mem_free(nice);
    mem_free(idle);
    mem_free(total);
}

- (void)checkLoad
{
    natural_t numCPUsU = 0U;
    [cpuUsageLock lock];
    kern_return_t err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, (processor_info_array_t *)&cpuInfo, &numCPUInfo);
    if(err == KERN_SUCCESS) {

        for(unsigned i = 0U; i < numCPUsU; ++i) {
            if(prevCPUInfo) {
                user[i] = cpuInfo[i].cpu_ticks[CPU_STATE_USER] - prevCPUInfo[i].cpu_ticks[CPU_STATE_USER];
                system[i] = cpuInfo[i].cpu_ticks[CPU_STATE_SYSTEM] - prevCPUInfo[i].cpu_ticks[CPU_STATE_SYSTEM];
                nice[i] = cpuInfo[i].cpu_ticks[CPU_STATE_NICE] - prevCPUInfo[i].cpu_ticks[CPU_STATE_NICE];
                idle[i] = cpuInfo[i].cpu_ticks[CPU_STATE_IDLE] - prevCPUInfo[i].cpu_ticks[CPU_STATE_IDLE];
                inUse[i] = user[i] + system[i] + nice[i];
                total[i] = inUse[i] + idle[i];
            } else {
                user[i] = cpuInfo[i].cpu_ticks[CPU_STATE_USER];
                system[i] = cpuInfo[i].cpu_ticks[CPU_STATE_SYSTEM];
                nice[i] = cpuInfo[i].cpu_ticks[CPU_STATE_NICE];
                idle[i] = cpuInfo[i].cpu_ticks[CPU_STATE_IDLE];
                inUse[i] = user[i] + system[i] + nice[i];
                total[i] = inUse[i] + idle[i];
            }
        }

        if(prevCPUInfo) {
            size_t prevCpuInfoSize = sizeof(integer_t) * numPrevCPUInfo;
            vm_deallocate(mach_task_self(), (vm_address_t)prevCPUInfo, prevCpuInfoSize);
        }

        prevCPUInfo = cpuInfo;
        numPrevCPUInfo = numCPUInfo;

        cpuInfo = nil;
        numCPUInfo = 0U;

    } else {
        NSLog(@"Error!");
    }
    [cpuUsageLock unlock];
}

- (void)updateLabel
{
    if (++cpuCheck >= 30) {
        cpuCheck = 0;
        [self checkLoad];
        NSMutableString *str = [NSMutableString string];
        for (unsigned i = 0; i < numCPUs; ++i) {
            Float32 load = (Float32)inUse[i] / total[i];
            [str appendFormat:
             @""
             "Core: %u\n"
             "load: %6.1f%%\tuser: %6.1f%%\tsystem: %6.1f%%\tnice: %6.1f%%\tidle: %6.1f%%\n\n"
             , i + 1,
             load * 100,
             (Float32)user[i] / total[i] * 100,
             (Float32)system[i] / total[i] * 100,
             (Float32)nice[i] / total[i] * 100,
             (Float32)idle[i] / total[i] * 100
             ];
        }
        loadLabel.text = str;
    }
    UInt32 score = engine.score;
    BOOL measurement = engine.measurement;
    scoreLabel.text = [@(score) description];
    if (score != prevScore) {
        prevScore = score;
        if (!scoreSlider.isTracking) {
            scoreSlider.value = score;
        }
        if (measurement) {
            remain = 60 * fps;
        }
    }
    if (measurement) {
        if (remain > 0) {
            --remain;
            remainLabel.text = [@((UInt32)(remain / fps) + 1) description];
        } else {
            remainLabel.text = nil;
            if (benchButton.selected) {
                [self stopMeasure];
            }
        }
    } else {
        remainLabel.text = nil;
    }
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
}

- (void)viewWillAppear:(BOOL)animated
{
    if (!displayLink) {
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateLabel)];
        displayLink.preferredFramesPerSecond = fps;
        [displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
    if (displayLink) {
        [displayLink invalidate];
        displayLink = nil;
    }
}

- (IBAction)soundToggle:(UISwitch *)sender
{
    engine.sound = sender.on;
}

- (void)startMeasure
{
    [[UIApplication sharedApplication] setIdleTimerDisabled:YES];
    scoreSlider.enabled = NO;
    engine.measurement = YES;
    [benchButton setSelected:YES];
    [benchButton setTitle:@"Stop" forState:UIControlStateNormal];
    remain = 60 * fps;
}

- (void)stopMeasure
{
    [[UIApplication sharedApplication] setIdleTimerDisabled:NO];
    engine.measurement = NO;
    scoreSlider.enabled = YES;
    [benchButton setSelected:NO];
    [benchButton setTitle:@"Start measurement" forState:UIControlStateNormal];
    remain = 0;
}

- (IBAction)toggleBenchmark:(id)sender
{
    if (benchButton.selected) {
        [self stopMeasure];
    } else {
        [self startMeasure];
    }
}

- (IBAction)changeScore:(UISlider *)sender
{
    UInt32 v = sender.value + 0.5f;
    engine.score = v;
    scoreSlider.value = v;
}

@end
