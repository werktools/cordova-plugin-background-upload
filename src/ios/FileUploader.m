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
    configuration.sessionSendsLaunchEvents = YES; // wake up the application when a task succeeds or fails
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
    [self createRequest: [NSURL URLWithString:payload[@"serverUrl"]]
                                method:[payload[@"requestMethod"] uppercaseString]
                              uploadId:payload[@"id"]
                               fileURL:[NSURL fileURLWithPath:payload[@"filePath"]]
                               headers: payload[@"headers"]
                            parameters:payload[@"parameters"]
                               fileKey:payload[@"fileKey"]
                     completionHandler:^(NSError *error, NSMutableURLRequest *request) {
        if (error)
            return handler(error);
        __block double lastProgressTimeStamp = 0;

        [[weakSelf.manager uploadTaskWithStreamedRequest:request
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
                               completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
            if (error) {
                NSLog(@"Error: %@", error);
            } else {
                NSLog(@"%@ %@", response, responseObject);
            }
        }] resume];
    }];
}

-(void)createRequest: (NSURL*)url
                             method:(NSString*)method
                           uploadId:(NSString*)uploadId
                            fileURL:(NSURL *)fileURL
                            headers:(NSDictionary*)headers
                         parameters:(NSDictionary*)parameters
                            fileKey:(NSString*)fileKey
                  completionHandler:(void (^)(NSError* error, NSMutableURLRequest* request))handler{
    AFHTTPRequestSerializer *serializer = [AFHTTPRequestSerializer serializer];
    NSError *error;
    NSMutableURLRequest *request =
    [serializer multipartFormRequestWithMethod:method
                                     URLString:url.absoluteString
                                    parameters:parameters
                     constructingBodyWithBlock:^(id<AFMultipartFormData> formData)
     {
        NSString *fileExtension = [fileURL pathExtension];
        NSString *UTI = (__bridge_transfer NSString *)UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)fileExtension, NULL);
        NSString *contentType = (__bridge_transfer NSString *)UTTypeCopyPreferredTagWithClass((__bridge CFStringRef)UTI, kUTTagClassMIMEType);

        NSLog(@"Got fileUrk: %@", fileURL);
        NSLog(@"Got key: %@", fileKey);
        NSLog(@"Got content type: %@", contentType);

        [formData
         appendPartWithFileURL: fileURL
         name:fileKey
         fileName:[fileURL.absoluteString lastPathComponent]
         mimeType:contentType
         error:nil
        ];
    }
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
