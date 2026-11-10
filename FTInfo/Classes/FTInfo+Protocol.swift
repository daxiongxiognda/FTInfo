//
//  FTInfo+Protocol.swift
//  FTReq
//
//  Created by 熊坤鹏 on 2026/10/30.
//

import FTReq

// MARK: - 用户更新类型

/// 用户信息更新的触发来源
/// - normal：普通更新（业务主动拉取）
/// - imLogin：IM 登录触发
/// - localLogin：本地登录态恢复
/// - remoteLogin：远端登录（如另一台设备登录）
public enum UserUpdateType {
    case normal
    case imLogin
    case localLogin
    case remoteLogin
}

// MARK: - 全局事件协议

/// 全局事件监听协议
/// - 用于解耦：登录/登出/用户信息变更/缓存清理等事件，由 FTInfo 统一广播给各业务模块
/// - AnyObject：只允许 class 遵循（便于用 NSPointerArray 弱引用持有）
public protocol GlobalEventable: AnyObject {
    /// 登录事件
    func login()
    /// 登出事件
    func logout()
    /// 用户信息变更（old/new + 更新类型）
    func userInfoUpdate(old: TMeGetData?, new: TMeGetData?, type: UserUpdateType)
    /// 清理磁盘缓存（低内存/退出登录时调用）
    func clearDiskCache()
    /// 清理内存缓存
    func clearMemory()
}

// 默认空实现：遵循方只需实现关心的方法，不用写一堆空方法
public extension GlobalEventable {
    func login() {}
    func logout() {}
    func userInfoUpdate(old: TMeGetData?, new: TMeGetData?, type: UserUpdateType) {}
    func clearDiskCache() {}
    func clearMemory() {}
}

// MARK: - FTInfo 的 Token 刷新能力

extension FTInfo: TokenRefreshable {

    /// 网络层检测到 token 过期时回调此方法
    /// - Parameter completion: 完成回调，err 为 nil 表示刷新成功
    ///
    /// ⚠️ 问题 1：无并发保护
    ///    多个请求同时 401 时，会**并发触发多次 refreshToken**，
    ///    服务端通常会因为 refreshToken 被重复使用而让后到的刷新失败，
    ///    导致部分请求刷新失败、用户被登出。
    ///    建议加锁 + 单飞（single-flight）：刷新进行中时，后续调用排队等待同一个结果。
    ///
    /// ⚠️ 问题 2：refreshToken 为空时直接报错，但没有清登录态
    ///    refreshToken 都拿不到，说明登录态已损坏，应主动触发登出清理，
    ///    否则后续请求会一直 401 → 一直报错。
    public func didReceiveTokenRefreshRequired(completion: ((_ err: Error?) -> Void)?) {
        guard let info = FTInfo.shared.loginInfo, !info.refreshToken.isEmpty else {
            
            completion?(NetworkError.tokenError("token失效"))
            return
        }

        refreshToken(refreshToken: info.refreshToken) { loginInfo, err in
            if let tempInfo = loginInfo {
                // 刷新成功：更新登录态并同步网络层配置（会触发 observer 的 login()）
                // ⚠️ 参数名 tempInfo 实际没用到，应该直接用 loginInfo
                FTInfo.shared.update(loginInfo: loginInfo, updateNetConfig: true)
            }
            completion?(err)
        }
    }

    /// 调用刷新 token 接口
    /// - Parameters:
    ///   - refreshToken: 刷新凭证
    ///   - completion: 返回新的登录信息 / 错误
    ///
    /// ⚠️ 问题 3：失败时没有区分错误类型
    ///    - refreshToken 过期 → 应该登出
    ///    - 网络错误 → 应该保留登录态、允许重试
    ///    当前统一把 error 透传，调用方无法区分，建议在错误里标记是否"凭证失效"。
    ///
    /// ⚠️ 问题 4：刷新成功后返回的 loginInfo 若 token 为空，没有校验
    ///    服务端异常时可能返回空 token，此时 update 会把空 token 写入网络层，
    ///    导致后续请求全部无鉴权失败。
    func refreshToken(refreshToken: String,
                      completion: ((_ loginInfo: TVerifyEnterRequestData?, _ err: NetworkError?) -> Void)?) {
        let req = CommonRequest(apiType: .refreshToken(refreshToken: refreshToken))
        NetworkManager.shared.normalRequest(apiConvertable: req, resType: TVerifyEnterRequestData.self) { res, error in
            completion?(res?.model, error)
        }
    }
}

