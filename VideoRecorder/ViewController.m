//
//  ViewController.m
//  VideoRecorder
//
//  Created by 王宁 on 2019/10/18.
//  Copyright © 2019 王宁. All rights reserved.
//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <MetalKit/MetalKit.h>
#import <Metal/Metal.h>
#import <AVKit/AVKit.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <GLKit/GLKit.h>
#include <simd/simd.h>

typedef struct {
    vector_float4 position;
    vector_float2 textureCoordinate;
} SceneVertex;

typedef struct {
    vector_float4 position;
    vector_float4 color;
} Vertex;

typedef struct {
    vector_float3 start;
    vector_float3 end;
    vector_float4 color;
} LineVertex;

typedef struct {
    int length;
    LineVertex paintVertices[10000000];
} PaintBuffer;

static const SceneVertex LargeScreenVertices[] =
{
    { {  1.0,  1.0, 0.0, 1.0 },  { 1.f, 0.f } },
    { { -1.0,  1.0, 0.0, 1.0 },  { 0.f, 0.f } },
    { { -1.0, -1.0, 0.0, 1.0 },  { 0.f, 1.f } },
    
    { {  1.0,  1.0, 0.0, 1.0 },  { 1.f, 0.f } },
    { {  1.0, -1.0, 0.0, 1.0 },  { 1.f, 1.f } },
    { { -1.0, -1.0, 0.0, 1.0 },  { 0.f, 1.f } },
};

static const float LineWidth            = 5.f;
static const float Space                = 12.f;
static const float SmallScreenWidth     = 144.5f;
static const float SmallScreenHeight    = 81.5f;
static const float ScreenWidth          = 667.f;
static const float ScreenHeight         = 375.f;
static const float RoundRadius          = 4;

static const float RoundRadiusWidth     = RoundRadius * 2 / ScreenWidth;
static const float RoundRadiusHeight    = RoundRadius * 2 / ScreenHeight;

static const int   VerticesPerCorner    = 1000;

static const float SmallScreenLeft      = - 1 + Space * 2 / ScreenWidth;
static const float SmallScreenRight     = - 1 + (Space + SmallScreenWidth) * 2 / ScreenWidth;
static const float SmallScreenBottom    = - 1 + Space * 2 / ScreenHeight;
static const float SmallScreenTop       = - 1 + (Space + SmallScreenHeight) * 2 / ScreenHeight;

@interface ViewController () <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, MTKViewDelegate>
{
    dispatch_queue_t captureQueue;
    dispatch_queue_t writeQueue;
    AVCaptureSession *captureSession;
    AVAssetWriterInput *videoWriterInput;
    AVAssetWriterInput *audioWriterInput;
    AVAssetWriterInputPixelBufferAdaptor *videoWriterInputPixelBufferAdaptor;
    AVAssetWriter *assetWriter;
    NSTimeInterval recordingStartTime;
    NSString *filePath;
    
    UIButton *recordBtn;
    UIButton *switchScreenButton;
    UIButton *paintbrushBtn;
    UILabel *writeFrameLabel;
    UILabel *drawViewLabel;
    
    BOOL isRecording;
    BOOL isVideoLargeScreen;
    
    BOOL firstTouch;
    CGPoint location;
    CGPoint previousLocation;
    
    SceneVertex smallScreenVertices[VerticesPerCorner * 4 * 3];
    PaintBuffer paintVertices;
}

@property (nonatomic, strong) MTKView *mtkView;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (atomic, strong) id<MTLTexture> texture;

@property (atomic, assign) CVMetalTextureCacheRef textureCache;

@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;
@property (nonatomic, strong) id<MTLRenderPipelineState> videoPipelineState;
@property (nonatomic, strong) id<MTLRenderPipelineState> paintPipelineState;

@property (nonatomic, strong) id<MTLBuffer> verticesBuffer;
@property (nonatomic, assign) NSUInteger numVertices;

@property (nonatomic, strong) id<MTLBuffer> smallScreenVerticesBuffer;
@property (nonatomic, assign) NSUInteger smallScreenNumVertices;

@property (atomic, strong) id<MTLTexture> videoCaptureTexture;

@end

@implementation ViewController

- (void)viewDidLoad{
    [super viewDidLoad];
    [self setupMTKView];
    [self setupSwitchScreenBtn];
    [self setupPaintbrushBtn];
    [self setupLabel];
    [self setupCapture];
    [self setupRecordBtn];
    
    isVideoLargeScreen = YES;
}

- (void)setupMTKView{
    self.mtkView = [[MTKView alloc] initWithFrame:self.view.bounds];
    self.mtkView.contentMode = UIViewContentModeScaleAspectFit;
    self.mtkView.device = MTLCreateSystemDefaultDevice();
    self.mtkView.preferredFramesPerSecond = 60;
    [self.view insertSubview:self.mtkView atIndex:0];
    self.mtkView.delegate = self;
    self.mtkView.framebufferOnly = NO;
    CVMetalTextureCacheCreate(NULL, NULL, self.mtkView.device, NULL, &_textureCache);
    self.commandQueue = [self.mtkView.device newCommandQueue];
    
    [self setupPipeline];
    [self setupVideoPipeline];
    [self setupPaintPipeline];
    [self setupVertex];
    [self setupTexture];
}

-(void)setupPipeline{
    id<MTLLibrary> defaultLibrary = [self.mtkView.device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"samplingShader"]; // 片元shader，samplingShader是函数名
    
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = self.mtkView.colorPixelFormat;
    self.pipelineState = [self.mtkView.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                             error:NULL];
}

- (void)setupVideoPipeline{
    id<MTLLibrary> defaultLibrary = [self.mtkView.device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"vertexShader"];
    id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"videoSamplingShader"];
    
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = self.mtkView.colorPixelFormat;
    self.videoPipelineState = [self.mtkView.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                                  error:NULL];
}

- (void)setupPaintPipeline{
    id<MTLLibrary> defaultLibrary = [self.mtkView.device newDefaultLibrary];
    id<MTLFunction> vertexFunction = [defaultLibrary newFunctionWithName:@"paintVertexShader"];
    id<MTLFunction> fragmentFunction = [defaultLibrary newFunctionWithName:@"paintSamplingShader"];
    
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineStateDescriptor.vertexFunction = vertexFunction;
    pipelineStateDescriptor.fragmentFunction = fragmentFunction;
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = self.mtkView.colorPixelFormat;
    self.paintPipelineState = [self.mtkView.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                                  error:NULL];
}

- (void)setupVertex{
    SceneVertex cornerVertices[VerticesPerCorner * 4];
    //leftTop
    for (int i = 0; i < VerticesPerCorner; i++) {
        float positionX = SmallScreenLeft + RoundRadiusWidth - RoundRadiusWidth * cosf(M_PI_2 * i / (VerticesPerCorner - 1));
        float positionY = SmallScreenTop - RoundRadiusHeight + RoundRadiusHeight * sinf(M_PI_2 * i / (VerticesPerCorner - 1));
        float textureCoordinateX = (RoundRadius - RoundRadius * cosf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenWidth;
        float textureCoordinateY = (RoundRadius - RoundRadius * sinf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenHeight;
        cornerVertices[i] = (SceneVertex){{positionX, positionY, 1.0, 1.0}, {textureCoordinateX, textureCoordinateY}};
    }
    
    //rightTop
    for (int i = 0; i < VerticesPerCorner; i++) {
        float positionX = SmallScreenRight - RoundRadiusWidth + RoundRadiusWidth * sinf(M_PI_2 * i / (VerticesPerCorner - 1));
        float positionY = SmallScreenTop - RoundRadiusHeight + RoundRadiusHeight * cosf(M_PI_2 * i / (VerticesPerCorner - 1));
        float textureCoordinateX = 1 - (RoundRadius - RoundRadius * sinf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenWidth;
        float textureCoordinateY = (RoundRadius - RoundRadius * cosf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenHeight;
        cornerVertices[i+VerticesPerCorner] = (SceneVertex){{positionX, positionY, 1.0, 1.0}, {textureCoordinateX, textureCoordinateY}};
    }
    
    //rightBottom
    for (int i = 0; i < VerticesPerCorner; i++) {
        float positionX = SmallScreenRight - RoundRadiusWidth + RoundRadiusWidth * cosf(M_PI_2 * i / (VerticesPerCorner - 1));
        float positionY = SmallScreenBottom + RoundRadiusHeight - RoundRadiusHeight * sinf(M_PI_2 * i / (VerticesPerCorner - 1));
        float textureCoordinateX = 1 - (RoundRadius - RoundRadius * cosf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenWidth;
        float textureCoordinateY = 1 - (RoundRadius - RoundRadius * sinf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenHeight;
        cornerVertices[i + VerticesPerCorner * 2] = (SceneVertex){{positionX, positionY, 1.0, 1.0}, {textureCoordinateX, textureCoordinateY}};
    }
    
    //leftBottom
    for (int i = 0; i < VerticesPerCorner; i++) {
        float positionX = SmallScreenLeft + RoundRadiusWidth - RoundRadiusWidth * sinf(M_PI_2 * i / (VerticesPerCorner - 1));
        float positionY = SmallScreenBottom + RoundRadiusHeight - RoundRadiusHeight * cosf(M_PI_2 * i / (VerticesPerCorner - 1));
        float textureCoordinateX = (RoundRadius - RoundRadius * sinf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenWidth;
        float textureCoordinateY = 1 - (RoundRadius - RoundRadius * cosf(M_PI_2 * i / (VerticesPerCorner - 1))) / SmallScreenHeight;
        cornerVertices[i + VerticesPerCorner * 3] = (SceneVertex){{positionX, positionY, 1.0, 1.0}, {textureCoordinateX, textureCoordinateY}};
    }
    
    for (int i = 0; i < VerticesPerCorner * 4; i++) {
        smallScreenVertices[i * 3] = cornerVertices[i];
        smallScreenVertices[i * 3 + 1] = cornerVertices[(i + 1) % (VerticesPerCorner * 4)];
        smallScreenVertices[i * 3 + 2] = (SceneVertex){{(SmallScreenLeft + SmallScreenRight) / 2, (SmallScreenTop + SmallScreenBottom) / 2, 0.1, 1.0}, {0.5, 0.5}};
    }
    
    self.verticesBuffer = [self.mtkView.device newBufferWithBytes:LargeScreenVertices
                                                           length:sizeof(LargeScreenVertices)
                                                          options:MTLResourceStorageModeShared];
    self.numVertices = sizeof(LargeScreenVertices) / sizeof(SceneVertex);
    
    self.smallScreenVerticesBuffer = [self.mtkView.device newBufferWithBytes:smallScreenVertices
                                                                      length:sizeof(smallScreenVertices)
                                                                     options:MTLResourceStorageModeShared];
    self.smallScreenNumVertices = sizeof(smallScreenVertices) / sizeof(SceneVertex);
}

- (void)setupTexture{
    UIImage *image = [UIImage imageNamed:@"background"];
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
    textureDescriptor.depth = 1;
    textureDescriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
    textureDescriptor.width = image.size.width;
    textureDescriptor.height = image.size.height;
    self.texture = [self.mtkView.device newTextureWithDescriptor:textureDescriptor];
    
    MTLRegion region = {{ 0, 0, 0 }, {image.size.width, image.size.height, 1}};
    Byte *imageBytes = [self loadImage:image];
    if (imageBytes) {
        [self.texture replaceRegion:region
                        mipmapLevel:0
                          withBytes:imageBytes
                        bytesPerRow:4 * image.size.width];
        free(imageBytes);
        imageBytes = NULL;
    }
}

- (void)setupCapture{
    captureSession = [[AVCaptureSession alloc] init];
    if ([captureSession canSetSessionPreset:AVCaptureSessionPresetHigh]) {
        [captureSession setSessionPreset:AVCaptureSessionPresetHigh];
    }
    
    NSError *error;
    AVCaptureDevice *videoCaptureDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:videoCaptureDevice error:&error];
    if ([captureSession canAddInput:videoInput]) {
        [captureSession addInput:videoInput];
    }
    AVCaptureDevice *audioCaptureDevice = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio] firstObject];
    AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audioCaptureDevice error:&error];
    if ([captureSession canAddInput:audioInput]) {
        [captureSession addInput:audioInput];
    }
    
    captureQueue = dispatch_queue_create("CaptureQueue", NULL);
    writeQueue = dispatch_queue_create("WriteQueue", NULL);
    AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    [videoOutput setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    videoOutput.alwaysDiscardsLateVideoFrames = NO;
    [videoOutput setSampleBufferDelegate:self queue:captureQueue];
    
    if ([captureSession canAddOutput:videoOutput]) {
        [captureSession addOutput:videoOutput];
    }
    AVCaptureAudioDataOutput *audioOutput = [[AVCaptureAudioDataOutput alloc] init];
    [audioOutput setSampleBufferDelegate:self queue:captureQueue];
    if ([captureSession canAddOutput:audioOutput]) {
        [captureSession addOutput:audioOutput];
    }
    
    AVCaptureConnection *connection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
    [connection setVideoOrientation:AVCaptureVideoOrientationLandscapeLeft];
    if (![captureSession isRunning]) {
        dispatch_async(captureQueue, ^{
            [self->captureSession startRunning];
        });
    }
}

- (void)setupRecordBtn{
    recordBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    recordBtn.frame = CGRectMake(0, 0, 100, 30);
    recordBtn.center =  CGPointMake(self.view.center.x, self.view.center.y - 50);
    [recordBtn setTitle:@"开始录制" forState:UIControlStateNormal];
    [recordBtn setTitle:@"结束录制" forState:UIControlStateSelected];
    [recordBtn addTarget:self action:@selector(recordBtnClicked) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:recordBtn];
}

- (void)setupSwitchScreenBtn{
    switchScreenButton = [UIButton buttonWithType:UIButtonTypeCustom];
    switchScreenButton.frame = CGRectMake(0, 0, 100, 30);
    switchScreenButton.center =  CGPointMake(self.view.center.x, self.view.center.y);
    [switchScreenButton setTitle:@"切换屏幕" forState:UIControlStateNormal];
    [switchScreenButton addTarget:self action:@selector(switchScreenBtnClicked) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:switchScreenButton];
}

- (void)setupPaintbrushBtn{
    paintbrushBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    paintbrushBtn.frame = CGRectMake(0, 0, 100, 30);
    paintbrushBtn.center =  CGPointMake(self.view.center.x, self.view.center.y + 50);
    [paintbrushBtn setTitle:@"打开画笔" forState:UIControlStateNormal];
    [paintbrushBtn setTitle:@"关闭画笔" forState:UIControlStateSelected];
    [paintbrushBtn addTarget:self action:@selector(paintbrushBtnClicked) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:paintbrushBtn];
}

- (void)setupLabel{
    writeFrameLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 30, 300, 30)];
    writeFrameLabel.backgroundColor = UIColor.clearColor;
    writeFrameLabel.textColor = UIColor.whiteColor;
    writeFrameLabel.font = [UIFont boldSystemFontOfSize: 10];
    [self.view addSubview:writeFrameLabel];
    
    drawViewLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 300, 30)];
    drawViewLabel.backgroundColor = UIColor.clearColor;
    drawViewLabel.textColor = UIColor.whiteColor;
    drawViewLabel.font = [UIFont boldSystemFontOfSize: 10];
    [self.view addSubview:drawViewLabel];
}

- (void)recordBtnClicked{
    recordBtn.selected = !recordBtn.selected;
    if (recordBtn.selected) {
        [self startRecord];
    } else {
        [self stopRecord];
    }
}

- (void)switchScreenBtnClicked{
    isVideoLargeScreen = !isVideoLargeScreen;
}

- (void)paintbrushBtnClicked {
    paintbrushBtn.selected = !paintbrushBtn.selected;
    if (!paintbrushBtn.selected) {
        paintVertices.length = 0;
    }
}

- (void)startRecord{
    filePath = [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/%ld.mp4",(long)NSDate.date.timeIntervalSince1970]];
    dispatch_async(captureQueue, ^{
        NSError *error;
        self->assetWriter = [[AVAssetWriter alloc]initWithURL:[NSURL fileURLWithPath:self->filePath] fileType:AVFileTypeMPEG4 error:&error];
        NSDictionary *settings = @{
                                   AVVideoCodecKey:AVVideoCodecH264,
                                   AVVideoWidthKey:@(1920),
                                   AVVideoHeightKey:@(1080),
                                   AVVideoCompressionPropertiesKey:@{
                                           AVVideoAverageBitRateKey:@(800000),
                                           AVVideoMaxKeyFrameIntervalKey:@(360)},
                                   };
        if ([self->assetWriter canApplyOutputSettings:settings forMediaType:AVMediaTypeVideo]) {
            self->videoWriterInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
            self->videoWriterInput.expectsMediaDataInRealTime = YES;
            NSDictionary* bufferAttributes = [NSDictionary dictionaryWithObjectsAndKeys:
                                              [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey,
                                              @(self.mtkView.drawableSize.width),kCVPixelBufferWidthKey,
                                              @(self.mtkView.drawableSize.height),kCVPixelBufferHeightKey,
                                              nil];
            
            self->videoWriterInputPixelBufferAdaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc] initWithAssetWriterInput:self->videoWriterInput
                                                                                            sourcePixelBufferAttributes:bufferAttributes];
            if ([self->assetWriter canAddInput:self->videoWriterInput]) {
                [self->assetWriter addInput:self->videoWriterInput];
            }
        }
        
        NSDictionary * audioSettings = @{AVFormatIDKey:@(kAudioFormatMPEG4AAC) ,
                                         AVEncoderBitRatePerChannelKey:@(64000),
                                         AVSampleRateKey:@(44100.0),
                                         AVNumberOfChannelsKey:@(1)};
        
        if ([self->assetWriter canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]) {
            self->audioWriterInput = [[AVAssetWriterInput alloc]initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
            self->audioWriterInput.expectsMediaDataInRealTime = YES;
            if ([self->assetWriter canAddInput:self->audioWriterInput]) {
                [self->assetWriter addInput:self->audioWriterInput];
            }
        }
        self->recordingStartTime = CACurrentMediaTime();
        if ([self->assetWriter startWriting]) {
            [self->assetWriter startSessionAtSourceTime:kCMTimeZero];
        }
        self->isRecording = YES;
    });
}

- (void)stopRecord{
    isRecording = NO;
    dispatch_async(captureQueue, ^{
        [self->videoWriterInput markAsFinished];
        [self->audioWriterInput markAsFinished];
        [self->assetWriter endSessionAtSourceTime: CMTimeMakeWithSeconds(CACurrentMediaTime()-self->recordingStartTime, NSEC_PER_USEC)];
        [self->assetWriter finishWritingWithCompletionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                AVPlayerViewController *playerViewController = [AVPlayerViewController new];
                AVPlayer *player = [[AVPlayer alloc] initWithURL:[NSURL fileURLWithPath:self->filePath]];
                playerViewController.player = player;
                [self presentViewController:playerViewController animated:YES completion:^{
                    [player play];
                }];
            });
        }];
    });
}

- (void)writeFrame:(id<MTLTexture>)texture {
    if (!assetWriter) {
        return;
    }
    if (!isRecording) {
        return;
    }
    dispatch_async(writeQueue, ^{
        CFTimeInterval frameStartTime = CACurrentMediaTime();
        if (!self->videoWriterInput.isReadyForMoreMediaData) {
            return;
        }
        CVPixelBufferRef pixelBuffer = NULL;
        CVReturn status = CVPixelBufferPoolCreatePixelBuffer(nil, self->videoWriterInputPixelBufferAdaptor.pixelBufferPool, &pixelBuffer);
        if (status != kCVReturnSuccess) {
            NSLog(@"create pixel buffer fail");
            return;
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, 0);
        void *pixelBufferBytes = CVPixelBufferGetBaseAddress(pixelBuffer);
        size_t bytesPerRow =  CVPixelBufferGetBytesPerRow(pixelBuffer);
        MTLRegion region = MTLRegionMake2D(0, 0, texture.width, texture.height);
        [texture getBytes:pixelBufferBytes bytesPerRow:bytesPerRow fromRegion:region mipmapLevel:0];
        CMTime time = CMTimeMakeWithSeconds(CACurrentMediaTime() - self->recordingStartTime, NSEC_PER_USEC);
        [self->videoWriterInputPixelBufferAdaptor appendPixelBuffer:pixelBuffer withPresentationTime:time];
        
        CVPixelBufferUnlockBaseAddress(pixelBuffer,0);
        CVPixelBufferRelease(pixelBuffer);
        
        CFTimeInterval frameTime = (CACurrentMediaTime() - frameStartTime) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->writeFrameLabel.text = [NSString stringWithFormat:@"write frame spent %.2f ms", frameTime];
        });
    });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(nonnull CMSampleBufferRef)sampleBuffer fromConnection:(nonnull AVCaptureConnection *)connection{
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        return;
    }
    CMFormatDescriptionRef formatDesc =  CMSampleBufferGetFormatDescription(sampleBuffer);
    CMMediaType mediaType = CMFormatDescriptionGetMediaType(formatDesc);
    if (mediaType == kCMMediaType_Video) {
        CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
        size_t width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0);
        size_t height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0);
        MTLPixelFormat pixelFormat = MTLPixelFormatRGBA8Unorm;

        CVMetalTextureRef texture = NULL;
        CVReturn status = CVMetalTextureCacheCreateTextureFromImage(NULL, self.textureCache, pixelBuffer, NULL, pixelFormat, width, height, 0, &texture);
        if(status == kCVReturnSuccess)
        {
            self.videoCaptureTexture = CVMetalTextureGetTexture(texture);
            CFRelease(texture);
        }
    }  else if (mediaType == kCMMediaType_Audio) {
        if (!assetWriter || !isRecording) {
            return;
        }
        if (audioWriterInput.isReadyForMoreMediaData) {
            [audioWriterInput appendSampleBuffer:sampleBuffer];
        }
    }
}

// Handles the start of a touch
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event{
    CGRect bounds = [self.view bounds];
    UITouch *touch = [[event touchesForView:self.mtkView] anyObject];
    firstTouch = YES;
    // Convert touch point from UIView referential to OpenGL one (upside-down flip)
    location = [touch locationInView:self.view];
    location.y = bounds.size.height - location.y;
}

// Handles the continuation of a touch.
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event{
    CGRect bounds = [self.view bounds];
    UITouch* touch = [[event touchesForView:self.mtkView] anyObject];
        
    // Convert touch point from UIView referential to OpenGL one (upside-down flip)
    if (firstTouch) {
        firstTouch = NO;
        previousLocation = [touch previousLocationInView:self.view];
        previousLocation.y = bounds.size.height - previousLocation.y;
    } else {
        location = [touch locationInView:self.view];
        location.y = bounds.size.height - location.y;
        previousLocation = [touch previousLocationInView:self.view];
        previousLocation.y = bounds.size.height - previousLocation.y;
    }
        
    // Render the stroke
    [self renderLineFromPoint:previousLocation toPoint:location];
}

// Handles the end of a touch event when the touch is a tap.
- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event{
    CGRect bounds = [self.view bounds];
    UITouch *touch = [[event touchesForView:self.mtkView] anyObject];
    if (firstTouch) {
        firstTouch = NO;
        previousLocation = [touch previousLocationInView:self.view];
        previousLocation.y = bounds.size.height - previousLocation.y;
        [self renderLineFromPoint:previousLocation toPoint:location];
    }
}

// Handles the end of a touch event.
- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event{
    // If appropriate, add code necessary to save the state of the application.
    // This application is not saving state.
}

- (void)renderLineFromPoint:(CGPoint)start toPoint:(CGPoint)end{
    if (paintbrushBtn.selected) {
        paintVertices.paintVertices[paintVertices.length++] = (LineVertex){
            {start.x, start.y, 1.0},
            {end.x, end.y, 1.0},
            {1.0, 1.0, 1.0, 1.0},
        };
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    
}

- (Byte *)loadImage:(UIImage *)image {
    CGImageRef spriteImage = image.CGImage;
    size_t width = CGImageGetWidth(spriteImage);
    size_t height = CGImageGetHeight(spriteImage);
    Byte * spriteData = (Byte *) calloc(width * height * 4, sizeof(Byte));
    CGContextRef spriteContext = CGBitmapContextCreate(spriteData, width, height, 8, CGImageGetBytesPerRow(spriteImage),
                                                       CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(spriteContext, CGRectMake(0, 0, width, height), spriteImage);
    
    CGContextRelease(spriteContext);
    
    return spriteData;
}

- (void)renderImage:(id<MTLRenderCommandEncoder>)renderEncoder {
    [renderEncoder setRenderPipelineState:self.pipelineState];
    [renderEncoder setVertexBuffer: isVideoLargeScreen ? self.smallScreenVerticesBuffer : self.verticesBuffer
                            offset:0
                           atIndex:0];
    [renderEncoder setFragmentTexture:self.texture
                              atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:0
                      vertexCount:isVideoLargeScreen ? self.smallScreenNumVertices : self.numVertices];
}

- (void)renderVideo:(id<MTLRenderCommandEncoder>)renderEncoder {
    if (self.videoCaptureTexture) {
        [renderEncoder setRenderPipelineState:self.videoPipelineState];
        [renderEncoder setVertexBuffer:isVideoLargeScreen ? self.verticesBuffer : self.smallScreenVerticesBuffer
                                    offset:0
                                   atIndex:0];
        [renderEncoder setFragmentTexture:self.videoCaptureTexture
                                  atIndex:0];
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                          vertexStart:0
                          vertexCount:isVideoLargeScreen ? self.numVertices : self.smallScreenNumVertices];
    }
}

- (void)renderPaint:(id<MTLRenderCommandEncoder>)renderEncoder {
    Vertex vertices[paintVertices.length*6];

    if (paintVertices.length == 0) return;

    for (int i = 0; i < paintVertices.length; i++) {
        vector_float3 start = paintVertices.paintVertices[i].start;
        vector_float3 end = paintVertices.paintVertices[i].end;
        vector_float4 color = paintVertices.paintVertices[i].color;
        
        
        float startX = 2 * start.x / self.view.frame.size.width - 1;
        float startY = 2 * start.y / self.view.frame.size.height - 1;
        float endX = 2 * end.x / self.view.frame.size.width - 1;
        float endY = 2 * end.y / self.view.frame.size.height - 1;
        
        vector_float4 position1 = {startX, startY, 1.0, 1.0};
        vector_float4 position2 = {endX, endY, 1.0, 1.0};
        
        
        vector_float4 v = position2 - position1;
        vector_float2 p0 = {position1.x, position1.y};
        vector_float2 v0 = {v.x, v.y};
        vector_float2 v1 = {(LineWidth / self.view.frame.size.width  * vector_normalize(v0)).y, -(LineWidth / self.view.frame.size.width  * vector_normalize(v0)).x};
        vector_float2 pa = p0 + v1;
        vector_float2 pb = p0 - v1;
        vector_float2 pc = p0 - v1 + v0;
        vector_float2 pd = p0 + v1 + v0;

        vector_float4 a = { pa.x, pa.y, 1.f, 1.f};
        vector_float4 b = { pb.x, pb.y, 1.f, 1.f};
        vector_float4 c = { pc.x, pc.y, 1.f, 1.f};
        vector_float4 d = { pd.x, pd.y, 1.f, 1.f};

        vertices[i*6] = (Vertex){a, color};
        vertices[i*6+1] = (Vertex){b, color};
        vertices[i*6+2] = (Vertex){c, color};
        vertices[i*6+3] = (Vertex){a, color};
        vertices[i*6+4] = (Vertex){c, color};
        vertices[i*6+5] = (Vertex){d, color};
    }
    
    [renderEncoder setRenderPipelineState:self.paintPipelineState];
    [renderEncoder setVertexBuffer:[self.mtkView.device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared]
                            offset:0
                           atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                      vertexStart:0
                      vertexCount:sizeof(vertices) / sizeof(Vertex)];
}

- (void)drawInMTKView:(MTKView *)view {
    CFTimeInterval startTime = CACurrentMediaTime();
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

    MTLRenderPassDescriptor *renderPassDescriptor = view.currentRenderPassDescriptor;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.5, 0.5, 1.0f);
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [renderEncoder setViewport:(MTLViewport){0.0, 0.0, self.mtkView.drawableSize.width, self.mtkView.drawableSize.height, 0.0, 1.0 }];
    if (isVideoLargeScreen) {
        [self renderVideo:renderEncoder];
        [self renderImage:renderEncoder];
        [self renderPaint:renderEncoder];
    } else {
        [self renderImage:renderEncoder];
        [self renderVideo:renderEncoder];
        [self renderPaint:renderEncoder];
    }
    
    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:view.currentDrawable];
    
    __weak typeof(self) weakSelf = self;
    id<MTLTexture> drawingTexture = self.mtkView.currentDrawable.texture;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
        float time = (CACurrentMediaTime() - startTime) * 1000;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->drawViewLabel.text = [NSString stringWithFormat:@"draw view spent %.2f ms", time];
        });
        
        [weakSelf writeFrame:drawingTexture];
    }];

    [commandBuffer commit];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskLandscapeLeft;
}

- (BOOL)shouldAutorotate
{
    return NO;
}

@end

