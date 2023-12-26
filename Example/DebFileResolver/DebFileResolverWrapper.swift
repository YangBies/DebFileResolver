//
//  DebResolver.swift
//  DylibExtract
//
//  Created by hy on 2023/11/9.
//

import Foundation
import DebFileResolver

class DebFileResolverWrapper {
    /// unarchive deb file
    /// - Parameters:
    ///   - filePath: deb file path
    ///   - completion: completion handler
    class func decompressDeb(filePath: String, completion: ((Bool, [String]?) -> Void)? = nil) {
        let item = DispatchWorkItem {
            DebFileResolver.decompressDeb(filePath, isControl: true) {isSuccess, parentPath, subDirs in
                if (!isSuccess) {
                    DispatchQueue.main.async {
                        completion?(false,nil)
                    }
                }else{
                    DebFileResolver.decompressDeb(filePath, isControl: false) {isSuccess, parentPath, subDirs in
                        if (!isSuccess) {
                            DispatchQueue.main.async {
                                completion?(false,nil)
                            }
                        }else{
                            var result:[String] = []
                            for subDir in subDirs {
                                let fullPath = parentPath + "/" + subDir
                                result.append(fullPath)
                            }
                            DispatchQueue.main.async {
                                completion?(true,result)
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.global().async(execute: item)
    }
    
    /// unarchive control file within deb file
    /// - Parameters:
    ///   - filePath: deb file path
    ///   - completion: completion handler
    class func decompressDebControl(filePath: String, completion: ((Bool, [String]?) -> Void)? = nil) {
        let item = DispatchWorkItem {
            DebFileResolver.decompressDeb(filePath, isControl: true) {isSuccess, parentPath, subDirs in
                if (!isSuccess) {
                    DispatchQueue.main.async {
                        completion?(false,nil)
                    }
                }else{
                    var result:[String] = []
                    for subDir in subDirs {
                        let fullPath = parentPath + "/" + subDir
                        result.append(fullPath)
                    }
                    DispatchQueue.main.async {
                        completion?(true,result)
                    }
                }
            }
        }
        DispatchQueue.global().async(execute: item)
    }
    
    /// unarchive data file within deb file
    /// - Parameters:
    ///   - filePath: deb file path
    ///   - completion: completion handler
    class func decompressDebData(filePath: String, completion: ((Bool, [String]?) -> Void)? = nil) {
        let item = DispatchWorkItem {
            DebFileResolver.decompressDeb(filePath, isControl: false) {isSuccess, parentPath, subDirs in
                if (!isSuccess) {
                    DispatchQueue.main.async {
                        completion?(false,nil)
                    }
                }else{
                    var result:[String] = []
                    for subDir in subDirs {
                        let fullPath = parentPath + "/" + subDir
                        result.append(fullPath)
                    }
                    DispatchQueue.main.async {
                        completion?(true,result)
                    }
                }
            }
        }
        DispatchQueue.global().async(execute: item)
    }
    
}
