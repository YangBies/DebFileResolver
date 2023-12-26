//
//  DebFileResolver.h
//  DebFileResolver
//
//  Created by hy on 2023/11/7.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN


typedef void(^decompressFinished)(BOOL success, NSString *parentPath, NSArray<NSString *>*subPaths);

@interface DebFileResolver : NSObject
/// resolver deb acquire control or data
/// - Parameters:
///   - filePath: deb file path
///   - isControl: is ideb Control
///   - completion: completion callback
+ (void)decompressDeb:(NSString *)filePath
            isControl:(BOOL)isControl
           completion:(nullable decompressFinished)completion;

@end

NS_ASSUME_NONNULL_END
