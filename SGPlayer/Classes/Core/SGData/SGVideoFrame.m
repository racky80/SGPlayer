//
//  SGVideoFrame.m
//  SGPlayer
//
//  Created by Single on 2018/1/22.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGVideoFrame.h"
#import "SGFrame+Internal.h"
#import "SGSWSContext.h"
#import "SGPlatform.h"
#import "SGMapping.h"
#import "imgutils.h"
#import <VideoToolbox/VideoToolbox.h>

@interface SGVideoFrame ()

{
    AVBufferRef * _buffer[SGFramePlaneCount];
}

@end

@implementation SGVideoFrame

- (instancetype)init
{
    if (self = [super init])
    {
        NSLog(@"%s", __func__);

        for (int i = 0; i < 8; i++)
        {
            _buffer[i] = nil;
        }
    }
    return self;
}

- (void)dealloc
{
    NSLog(@"%s", __func__);
    
    for (int i = 0; i < 8; i++)
    {
        av_buffer_unref(&_buffer[i]);
        _buffer[i] = nil;
    }
}

- (void)clear
{
    [super clear];
    
    _format = AV_PIX_FMT_NONE;
    _width = 0;
    _height = 0;
    _key_frame = 0;
    for (int i = 0; i < SGFramePlaneCount; i++)
    {
        self->_data[i] = nil;
        self->_linesize[i] = 0;
    }
    self->_pixelBuffer = nil;
}

- (void)configurateWithTrack:(SGTrack *)track
{
    [super configurateWithTrack:track];
    
    _format = self.core->format;
    _width = self.core->width;
    _height = self.core->height;
    _key_frame = self.core->key_frame;
    [self fillData];
}

- (void)fillData
{
    BOOL resample = NO;
    int planes = 0;
    int linesize[8] = {0};
    int linecount[8] = {0};
    if (self.format == AV_PIX_FMT_YUV420P)
    {
        planes = 3;
        linesize[0] = self.width;
        linesize[1] = self.width / 2;
        linesize[2] = self.width / 2;
        linecount[0] = self.height;
        linecount[1] = self.height / 2;
        linecount[2] = self.height / 2;
    }
    else if (self.format == AV_PIX_FMT_VIDEOTOOLBOX)
    {
        self->_pixelBuffer = (CVPixelBufferRef)(self.core->data[3]);
    }
    for (int i = 0; i < planes; i++)
    {
        resample = resample || (self.core->linesize[i] != linesize[i]);
    }
    if (resample)
    {
        for (int i = 0; i < planes; i++)
        {
            int size = linesize[i] * linecount[i] * sizeof(uint8_t);
            if (!_buffer[i] || _buffer[i]->size < size)
            {
                av_buffer_realloc(&_buffer[i], size);
            }
            av_image_copy_plane(_buffer[i]->data,
                                linesize[i],
                                self.core->data[i],
                                self.core->linesize[i],
                                linesize[i] * sizeof(uint8_t),
                                linecount[i]);
        }
        for (int i = 0; i < planes; i++)
        {
            self->_data[i] = _buffer[i]->data;
            self->_linesize[i] = linesize[i];
        }
    }
    else
    {
        for (int i = 0; i < SGFramePlaneCount; i++)
        {
            self->_data[i] = self.core->data[i];
            self->_linesize[i] = self.core->linesize[i];
        }
    }
}

- (UIImage *)image
{
    if (self.width == 0 || self.height == 0)
    {
        return nil;
    }
    enum AVPixelFormat src_format = self.format;
    enum AVPixelFormat dst_format = AV_PIX_FMT_RGB24;
    const uint8_t * src_data[SGFramePlaneCount] = {nil};
    uint8_t * dst_data[SGFramePlaneCount] = {nil};
    int src_linesize[SGFramePlaneCount] = {0};
    int dst_linesize[SGFramePlaneCount] = {0};
    
    if (src_format == AV_PIX_FMT_VIDEOTOOLBOX)
    {
        if (!self->_pixelBuffer)
        {
            return nil;
        }
        OSType type = CVPixelBufferGetPixelFormatType(self->_pixelBuffer);
        src_format = SGPixelFormatAV2FF(type);
        
        CVReturn error = CVPixelBufferLockBaseAddress(self->_pixelBuffer, kCVPixelBufferLock_ReadOnly);
        if (error != kCVReturnSuccess)
        {
            return nil;
        }
        if (CVPixelBufferIsPlanar(self->_pixelBuffer))
        {
            int planes = (int)CVPixelBufferGetPlaneCount(self->_pixelBuffer);
            for (int i = 0; i < planes; i++)
            {
                src_data[i] = CVPixelBufferGetBaseAddressOfPlane(self->_pixelBuffer, i);
                src_linesize[i] = (int)CVPixelBufferGetBytesPerRowOfPlane(self->_pixelBuffer, i);
            }
        }
        else
        {
            src_data[0] = CVPixelBufferGetBaseAddress(self->_pixelBuffer);
            src_linesize[0] = (int)CVPixelBufferGetBytesPerRow(self->_pixelBuffer);
        }
        CVPixelBufferUnlockBaseAddress(self->_pixelBuffer, kCVPixelBufferLock_ReadOnly);
    }
    else
    {
        for (int i = 0; i < SGFramePlaneCount; i++)
        {
            src_data[i] = self.core->data[i];
            src_linesize[i] = self.core->linesize[i];
        }
    }
    
    if (src_format == AV_PIX_FMT_NONE || !src_data[0] || !src_linesize[0])
    {
        return nil;
    }
    
    SGSWSContext * context = [[SGSWSContext alloc] init];
    context.src_format = src_format;
    context.dst_format = dst_format;
    context.width = self.width;
    context.height = self.height;
    if (![context open])
    {
        return nil;
    }
    
    int result = av_image_alloc(dst_data, dst_linesize, self.width, self.height, dst_format, 1);
    if (result < 0)
    {
        return nil;
    }
    result = [context scaleWithSrc_data:src_data src_linesize:src_linesize dst_data:dst_data dst_linesize:dst_linesize];
    if (result < 0)
    {
        av_freep(dst_data);
        return nil;
    }
    SGPLFImage * image = SGPLFImageWithRGBData(dst_data[0], dst_linesize[0], self.width, self.height);
    av_freep(dst_data);
    return image;
}

@end
