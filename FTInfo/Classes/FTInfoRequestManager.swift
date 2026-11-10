//
//  FTInfoRequestManager.swift
//  FTReq
//
//  Created by 熊坤鹏 on 2026/10/30.
//

import Foundation
import RxSwift
import FTReq

/// 单次请求的回调包装
struct UserGetRequestCallback {
    /// 原始请求的 id 列表（注意：与 map 的 key 不同，这里存的是未排序的原始 ids）
    let ids: [Int64]
    /// 成功回调
    let success: ([TMeGetData]) -> Void
    /// 失败回调
    let error: (Error) -> Void
}

/// 用户信息请求合并管理器
/// - 目的：同一批 id 并发请求时，只发一次网络请求，结果广播给所有等待者
/// - 用 [Int64] 数组作为 key 做去重
public class FTInfoRequestManager {
    static let shared = FTInfoRequestManager()

    /// key: 排序后的 ids 数组；value: 等待该批 ids 结果的所有回调
    private var callBackMap = Dictionary<[Int64], [UserGetRequestCallback]>()
    /// ⚠️ 声明了但从未使用，是死代码
    private var cache = Set<[Int64]>()
    /// 串行队列，保护 callBackMap 的读写
    private let serialQueue = DispatchQueue(label: "FTInfoRequestManager.serialqueue")

    /// 注册一次请求
    /// - Parameters:
    ///   - ids: 请求的 id 列表
    ///   - success/error: 结果回调
    ///   - completion: 是否需要真正发起网络请求（true = 已有同批请求在途，无需再发）
    ///
    /// ⚠️ 严重问题 1：completion 在 serialQueue.async 里调用，
    ///   调用方（FTInfo.userGetRequest）拿到 completion 时是异步的，
    ///   若调用方在 completion 里做 UI 操作，需自行切主线程。
    ///   更关键的是：completion 是异步回调，但调用方看起来是按同步逻辑写的，
    ///   容易产生"以为已注册完，实际还没"的时序问题。
    ///
    /// ⚠️ 严重问题 2：key 用 [Int64] 排序数组，
    ///   但 UserGetRequestCallback 里存的是原始未排序的 ids。
    ///   这本身不算错，但要注意 success/failure 里也必须用"排序后的 ids"去取，
    ///   否则取不到。当前 success/failure 确实用了 sorted，这点是对的。
    ///
    /// ⚠️ 严重问题 3：没有超时/清理机制。
    ///   如果网络请求永远不回调（比如被取消、或调用方忘了调 success/failure），
    ///   callBackMap 里的条目永远不会移除，回调闭包也不会释放，
    ///   造成内存泄漏 + 后续同批请求永远被判定为"已存在"而不再发请求。
    func addRequest(ids: [Int64],
                    success: @escaping (_ data: [TMeGetData]) -> Void,
                    error: @escaping (_ error: Error) -> Void,
                    completion: @escaping (Bool) -> Void) {
        serialQueue.async {
            var sortIdsArr = ids.sorted { $0 < $1 }
            let isExist = self.callBackMap.keys.contains(sortIdsArr)
            let callBack = UserGetRequestCallback(ids: ids, success: success, error: error)
            if isExist {
                self.callBackMap[sortIdsArr]?.append(callBack)
            } else {
                self.callBackMap[sortIdsArr] = [callBack]
            }
            let value = isExist ? true : false
            completion(value)
        }
    }

    /// 请求成功，分发结果给所有等待者
    /// - Parameters:
    ///   - ids: 原始请求的 ids（内部会排序后作为 key 取）
    ///   - value: 请求结果
    func success(ids: [Int64], value: [TMeGetData]) {
        serialQueue.async {
            let callBackList = self.callBackMap.removeValue(forKey: ids.sorted { $0 < $1 })
            callBackList?.forEach({ back in
                DispatchQueue.main.async {
                    back.success(value)
                }
            })
        }
    }

    /// 请求失败，分发给所有等待者
    func failure(ids: [Int64], error: NetworkError) {
        serialQueue.async {
            let callBackList = self.callBackMap.removeValue(forKey: ids.sorted { $0 < $1 })
            callBackList?.forEach({ back in
                DispatchQueue.main.async {
                    back.error(error)
                }
            })
        }
    }
}
