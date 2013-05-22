/*
 Copyright (c) 2013, OpenEmu Team
 

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SMSGameCore.h"
#import <OpenEmuBase/OERingBuffer.h>
#import "OESMSSystemResponderClient.h"

#import "libsms.h"
#import "color.h"
#import "resampler.h"

@interface SMSGameCore () <OESMSSystemResponderClient>
{
    uint16_t      controllerMask1;
    uint16_t      controllerMask2;
    bool          systemPause;
    int           width;
    int           height;
    Color         pixelFormatConverter;
    Resampler     resampler;
    NSData       *rom;
    NSString     *romName;
    unsigned int *videoBuffer;
}
@end

@implementation SMSGameCore

static SMSGameCore *current;

#pragma mark Callbacks

void videoCallback(const unsigned short* frame, unsigned width, unsigned height, unsigned modeId, bool secondGG)
{
    current->width = width;
    current->height = height;
    
    unsigned gpu_pitch = width * sizeof(unsigned int);
    current->pixelFormatConverter.update();
    current->pixelFormatConverter.active_filter->render((Color::Mode)modeId, current->videoBuffer, gpu_pitch, (u16*)frame, width, height);
}

static void audioCallback(signed sampleLeft, signed sampleRight, unsigned soundChip)
{
    if(soundChip == SMS_SOUND_YM2413)
    {   
        signed samples[] = { sampleLeft, sampleRight };
        current->resampler.sample(samples);
        while(current->resampler.pending()) {
            current->resampler.read(samples);
            [[current ringBufferAtIndex:1] write:&samples[0] maxLength:2];
            [[current ringBufferAtIndex:1] write:&samples[1] maxLength:2];
        }
    }
    else
    {
        [[current ringBufferAtIndex:0] write:&sampleLeft maxLength:2];
        [[current ringBufferAtIndex:0] write:&sampleRight maxLength:2];
    }
}

static signed inputCallback (unsigned port, unsigned deviceId, unsigned objectId)
{
    if(deviceId == SMS_DEVICE_JOYPAD)
    {
        if(port == SMS_PORT_1)
            return (current->controllerMask1 >> objectId);
        else
            return (current->controllerMask2 >> objectId);
    }
    else if(deviceId == SMS_DEVICE_MISC && objectId == SMS_INPUT_PAUSE)
    {
        return current->systemPause;
    }

    return 0;
}

#pragma mark Core Implementation

- (id)init
{
    self = [super init];
    if(self != nil)
    {
        videoBuffer     = (unsigned int *) malloc(262 * 240 * sizeof(unsigned int));
        width           = 256;
        height          = 201;
        controllerMask1 = 0;
        controllerMask2 = 0;
        
        current = self;
    }
    return self;
}

- (void)dealloc
{
    free(videoBuffer);
}

- (void)executeFrame
{
    smsRun();
}

- (void)setupEmulation
{
    smsSetVideoRefresh(videoCallback);
    smsSetAudioSample(audioCallback);
    smsSetInputState(inputCallback);

    smsSetDevice(SMS_PORT_1, SMS_DEVICE_JOYPAD);
    smsSetDevice(SMS_PORT_2, SMS_DEVICE_JOYPAD);

    smsEnableYamahaSoundChip(true);
    resampler.setFrequency(49716.0, 44100.0);
}

- (BOOL)loadFileAtPath:(NSString*)path
{
    romName = [path copy];

    rom = [NSData dataWithContentsOfFile:[romName stringByStandardizingPath]];
    if(rom == nil) return NO;

    unsigned int size = [rom length];
    uint8_t *data = (uint8_t *)[rom bytes];

    smsLoad(data, size);
    
    smsPower();

    return YES;
}

- (void)resetEmulation
{
    smsReset();
}

- (void)stopEmulation
{
    smsUnload();
    
    [super stopEmulation];
}

- (OEIntRect)screenRect
{
    return OEIntRectMake(0, 0, width, height);
}

- (OEIntSize)bufferSize
{
    return OEIntSizeMake(262, 240);
}

- (OEIntSize)aspectSize
{
    return OEIntSizeMake(width, height);
}

- (const void *)videoBuffer
{
    return videoBuffer;
}

- (GLenum)pixelFormat
{
    return GL_BGRA;
}

- (GLenum)pixelType
{
    return GL_UNSIGNED_INT_8_8_8_8_REV;
}

- (GLenum)internalPixelFormat
{
    return GL_RGB8;
}

- (NSUInteger)audioBufferCount
{
    return 2;
}

- (double)audioSampleRateForBuffer:(NSUInteger)buffer
{
    return 44100;
}

- (NSUInteger)channelCountForBuffer:(NSUInteger)buffer
{
    return 2;
}

- (BOOL)saveStateToFileAtPath:(NSString *)fileName
{
    unsigned int   saveStateSize = smsSavestateSize();
    unsigned char *saveStateData = (unsigned char *) malloc(saveStateSize);

    if(!smsSaveState(saveStateData, saveStateSize))
    {
        NSLog(@"Couldn't save state");
        return NO;
    }

    FILE  *saveStateFile = fopen([fileName UTF8String], "wb");
    size_t bytesWritten  = fwrite(saveStateData, sizeof(unsigned char), saveStateSize, saveStateFile);

    free(saveStateData);

    if(bytesWritten != saveStateSize)
    {
        NSLog(@"Couldn't write save state");
        return NO;
    }
    
    fclose(saveStateFile);
    return YES;
}

- (BOOL)loadStateFromFileAtPath:(NSString *)fileName
{
    FILE *saveStateFile = fopen([fileName UTF8String], "rb");
    if(!saveStateFile)
    {
        NSLog(@"Could not open save state file");
        return NO;
    }

    unsigned int saveStateSize   = smsSavestateSize();
    unsigned char *saveStateData = (unsigned char *) malloc(saveStateSize);

    if(!fread(saveStateData, sizeof(uint8_t), saveStateSize, saveStateFile))
    {
        NSLog(@"Couldn't read file");
        return NO;
    }
    fclose(saveStateFile);

    if(!smsLoadState(saveStateData, saveStateSize))
    {
        NSLog(@"Couldn't load save state");
        return NO;
    }

    free(saveStateData);
    return YES;
}

#pragma mark Core Input

- (oneway void)didPushSMSButton:(OESMSButton)button forPlayer:(NSUInteger)player
{
    if(player == 1)
        controllerMask1 |= 1 << button;
    else
        controllerMask2 |= 1 << button;
}

- (oneway void)didReleaseSMSButton:(OESMSButton)button forPlayer:(NSUInteger)player
{
    if(player == 1)
        controllerMask1 &= ~(1 << button);
    else
        controllerMask2 &= ~(1 << button);
}

- (oneway void)didPushSMSResetButton
{}

- (oneway void)didReleaseSMSResetButton
{}

- (oneway void)didPushSMSStartButton
{
    systemPause = true;
}

- (oneway void)didReleaseSMSStartButton
{
    systemPause = false;
}

@end