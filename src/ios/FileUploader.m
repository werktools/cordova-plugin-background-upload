#import "FileUploader.h"
@interface FileUploader()
@property (nonatomic, strong) NSMutableDictionary* responsesData;
@property (nonatomic, strong) AFURLSessionManager *manager;
@end

@implementation FileUploader
static NSInteger _parallelUploadsLimit = 1;
static FileUploader *singletonObject = nil;
static NSString * kUploadUUIDStrPropertyKey = @"com.spoonconsulting.plugin-background-upload.UUID";
+(instancetype)sharedInstance{
    if (!singletonObject)
        singletonObject = [[FileUploader alloc] init];
    return singletonObject;
}

-(id)init{
    self = [super init];
    if (self == nil)
        return nil;
    [UploadEvent setupStorage];
    self.responsesData = [[NSMutableDictionary alloc] init];
    NSURLSessionConfiguration* configuration = [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:[[NSBundle mainBundle] bundleIdentifier]];
    configuration.HTTPMaximumConnectionsPerHost = FileUploader.parallelUploadsLimit;
    configuration.sessionSendsLaunchEvents = NO;
    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    __weak FileUploader *weakSelf = self;
    [self.manager setTaskDidCompleteBlock:^(NSURLSession * _Nonnull session, NSURLSessionTask * _Nonnull task, NSError * _Nullable error) {
        NSString* uploadId = [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:task.originalRequest];
        NSLog(@"[BackgroundUpload] Task %@ completed with error %@", uploadId, error);
        if (!error){
            NSData* serverData = weakSelf.responsesData[@(task.taskIdentifier)];
            NSString* serverResponse = serverData ? [[NSString alloc] initWithData:serverData encoding:NSUTF8StringEncoding] : @"";
            [weakSelf.responsesData removeObjectForKey:@(task.taskIdentifier)];
            [weakSelf saveAndSendEvent:@{
                @"id" : uploadId,
                @"state" : @"UPLOADED",
                @"statusCode" : @(((NSHTTPURLResponse *)task.response).statusCode),
                @"serverResponse" : serverResponse
            }];
        } else {
            [weakSelf saveAndSendEvent:@{
                @"id" : uploadId,
                @"state" : @"FAILED",
                @"error" : error.localizedDescription,
                @"errorCode" : @(error.code)
            }];
        }
    }];

    [self.manager setDataTaskDidReceiveDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSData * _Nonnull data) {
        NSMutableData *responseData = weakSelf.responsesData[@(dataTask.taskIdentifier)];
        if (!responseData) {
            weakSelf.responsesData[@(dataTask.taskIdentifier)] = [NSMutableData dataWithData:data];
        } else {
            [responseData appendData:data];
        }
    }];
    return self;
}

-(void)saveAndSendEvent:(NSDictionary*)data{
    UploadEvent*event = [UploadEvent create:data];
    [self sendEvent:[event dataRepresentation]];
}

-(void)sendEvent:(NSDictionary*)info{
    [self.delegate uploadManagerDidReceiveCallback:info];
}

+(NSInteger)parallelUploadsLimit {
    return _parallelUploadsLimit;
}

+(void)setParallelUploadsLimit:(NSInteger)value {
    _parallelUploadsLimit = value;
}

-(void)addUpload:(NSDictionary *)payload completionHandler:(void (^)(NSError* error))handler{
    __weak FileUploader *weakSelf = self;
    NSURL *filePath = [NSURL fileURLWithPath:payload[@"filePath"]];
    [self createRequest: [NSURL URLWithString:payload[@"serverUrl"]]
                              uploadId:payload[@"id"]
                               headers: payload[@"headers"]
                            parameters:payload[@"parameters"]
                     completionHandler:^(NSError *error, NSMutableURLRequest *request) {
        if (error)
            return handler(error);
        __block double lastProgressTimeStamp = 0;

        NSURLSessionUploadTask *uploadTask;
        uploadTask = [weakSelf.manager uploadTaskWithRequest:request
                                        fromFile:filePath
                                        progress:^(NSProgress * _Nonnull uploadProgress)
          {
            float roundedProgress = roundf(10 * (uploadProgress.fractionCompleted*100)) / 10.0;
            NSLog(@"[BackgroundUpload] Task %@ progression %f", [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request], roundedProgress);
            NSTimeInterval currentTimestamp = [[NSDate date] timeIntervalSince1970];
            if (currentTimestamp - lastProgressTimeStamp >= 1){
                lastProgressTimeStamp = currentTimestamp;
                [weakSelf sendEvent:@{
                    @"progress" : @(roundedProgress),
                    @"id" : [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:request],
                    @"state": @"UPLOADING"
                }];
            }
        }
                                            completionHandler:nil];
        [uploadTask resume];
    }];
}

-(NSURL*)tempFilePathForUpload:(NSString*)uploadId{
    NSString* path = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)[0];
    return [NSURL fileURLWithPath:[path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.request",uploadId]]];
}

-(void)createRequest: (NSURL*)url
                           uploadId:(NSString*)uploadId
                            headers:(NSDictionary*)headers
                         parameters:(NSDictionary*)parameters
                  completionHandler:(void (^)(NSError* error, NSMutableURLRequest* request))handler{
    AFHTTPRequestSerializer *serializer = [AFHTTPRequestSerializer serializer];
    NSError *error;
    NSMutableURLRequest *request =
    [serializer requestWithMethod:@"PUT"
                    URLString:url.absoluteString
                    parameters:parameters
                    error:&error];
    if (error)
        return handler(error, nil);
    for (NSString *key in headers) {
        [request setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    [NSURLProtocol setProperty:uploadId forKey:kUploadUUIDStrPropertyKey inRequest:request];
    
    handler(error, request);
}

-(void)removeUpload:(NSString*)uploadId{
    NSURLSessionUploadTask *correspondingTask =
    [[self.manager.uploadTasks filteredArrayUsingPredicate: [NSPredicate predicateWithBlock:^BOOL(NSURLSessionUploadTask* task, NSDictionary *bindings) {
        NSString* currentId = [NSURLProtocol propertyForKey:kUploadUUIDStrPropertyKey inRequest:task.originalRequest];
        return [uploadId isEqualToString:currentId];
    }]] firstObject];
    [correspondingTask cancel];
}

-(void)acknowledgeEventReceived:(NSString*)eventId{
    [[UploadEvent eventWithId:eventId] destroy];
}
@end
