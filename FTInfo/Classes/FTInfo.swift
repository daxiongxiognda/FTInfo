//
//  FTInfo.swift
//  FTInfo
//
//  Created by 熊坤鹏 on 2026/10/30.
//

import FTTool
import FTLogger
import FTKv
import FTReq
import RxSwift
import RxCocoa

/// 全局用户信息管理器（单例）
/// - 管理当前登录用户的 profileInfo（用户资料）与 loginInfo（登录态）
/// - 通过 loginObservers 通知各业务模块登录/登出/用户信息变更
/// - 负责 token 刷新、前台回到前台时刷新基础配置、低内存设备的内存监控与释放
public class FTInfo {
    public static let shared = FTInfo()

    /// 我的用户信息（完整 TMeGetData，包含 22 个子资源）
    public private(set) var profileInfo: TMeGetData?

    /// 我的登录信息（token、refreshToken、userID 等）
    public private(set) var loginInfo: TVerifyEnterRequestData?

    // MARK: - 登录状态观察者

    /// 登录状态观察者集合（弱引用，NSPointerArray 弱持有，避免循环引用）
    internal var loginObservers: NSPointerArray = NSPointerArray.weakObjects()

    /// 添加登录观察者
    public func addLoginObserver(_ observer: GlobalEventable) {
        loginObservers.ft.addObject(observer)
    }

    /// 清理已释放的观察者（compact 移除 nil 槽位）
    public func clearLoginObservers() {
        loginObservers.compact()
    }

    /// 内存监控的冷却时间（毫秒），避免频繁触发内存释放通知
    private var memoryTimeInterval: Double = 0

    // MARK: - 初始化

    private init() {
        // 注册 token 刷新器（网络层 token 过期时回调本类刷新）
        NetworkManager.shared.addTokenRefresher(self)

        // 前台回到前台时，刷新基础配置（baseConfiguration）
        // ⚠️ 问题：每次回前台都请求一次配置，未做节流/去重；
        //   且 [weak self] 后只取 token，self 释放时静默不请求（可接受）
//        NotificationCenter.default.addObserver(
//            forName: UIApplication.willEnterForegroundNotification,
//            object: nil,
//            queue: nil
//        ) { [weak self] _ in
//            guard let token = self?.loginInfo?.token, !token.isEmpty else { return }
//            let req = CommonRequest(
//                apiType: .configurationResource(resourceNames: .baseConfiguration),
//                hudConfig: nil
//            )
//            NetworkManager.shared.send(req, resType: TConfigurationResourceData.self) { result in
//                switch result {
//                case .success(let data):
//                    BaseConfiguration.shard.setValue(data: data)
//                case .failure:
//                    // ⚠️ 失败静默忽略，无日志，排查问题时无迹可寻
//                    break
//                }
//            }
//        }

        // 低内存设备（总内存 < 3000MB）才启动内存监控
        // 监控间隔 2 秒，App 占用内存超过阈值时通知观察者释放内存
        // ⚠️ 问题：guard 之后直接 return，只有低内存设备才注册定时器，逻辑正确；
        //   但内存监控只在 init 时判断设备内存，后续无法动态开启/关闭
//        guard deviceTotalMem < 3000 else { return }
//        TTGcdTimer.shared.scheduledTimer(identifier: "kMemoryMonitor", interval: 2000) { [weak self] in
//            guard let strongSelf = self else { return }
//            strongSelf.memoryTimeInterval -= 2000
//            let usage = AppMemoryUtil.useMemoryForApp()
//            // 未超阈值，或仍在冷却期内，不处理
//            guard usage > appMemThreshold, strongSelf.memoryTimeInterval < 1 else { return }
//            // 触发释放，并设置 120 秒冷却
//            strongSelf.memoryTimeInterval = 120000
//            // 主线程回调观察者释放内存
//            DispatchQueue.main.async {
//                for index in 0..<strongSelf.loginObservers.count {
//                    let observer = strongSelf.loginObservers.ft.object(at: index) as? GlobalEventable
//                    observer?.clearMemory()
//                }
//            }
//        }
    }

    // MARK: - 登录信息

    /// 从本地恢复登录态
    /// - Parameters:
    ///   - loginInfo: 本地保存的登录信息
    ///   - completion: 完成回调
    public func loginFromLocal(loginInfo: TVerifyEnterRequestData, completion: BoolClosure? = nil) {
        if loginInfo.userID <= 0 {
            // userID 非法时上报一次异常（用于监控本地登录态异常）
      
            FTLog.error("local_login_invalid_user_identifier")
        }
        // 更新登录信息并同步网络配置
        FTInfo.shared.update(loginInfo: loginInfo, updateNetConfig: true)
        completion?(true)

        // 设置完 loginInfo 后再同步用户信息，防止拿不到 token
        let uid = loginInfo.userID
        if uid > 0 {
            FTKv.shared.setup(uid: uid)
            let existMeData = FTKv.shared.value(TMeGetData.self, forKey: .me)
            FTInfo.shared.profileInfo = existMeData
            // ⚠️ 这里 oldPb 传 nil，但 meInfoUpdate 内部用的是 profileInfo 而不是 oldPb 参数，
            //   实际通知的 old 值是刚赋值的 profileInfo（即 new 值），old/new 相同，见下方分析
            FTInfo.shared.meInfoUpdate(oldPb: nil, newPb: existMeData, type: .localLogin)
        }
    }

    /// 更新登录信息
    /// - Parameters:
    ///   - loginInfo: 新的登录信息，nil 表示登出
    ///   - updateNetConfig: 是否同步更新网络层配置并触发登录通知
    public func update(loginInfo: TVerifyEnterRequestData?, updateNetConfig: Bool = false) {
        if let loginInfo = loginInfo, loginInfo.userID <= 0 || loginInfo.token.isEmpty {
            // 登录态不完整（userID 非法或 token 为空）时上报异常

            FTLog.error("login_state_incomplete_登录态不完整")
        }
        self.loginInfo = loginInfo

        if updateNetConfig {
            // 同步 token 到网络层
            NetworkManager.shared.setConfig(token: loginInfo?.token, refreshToken: loginInfo?.refreshToken)
            NotificationCenter.default.post(
                name: FTReqNotifiName.updateNetHeader.name,
                object: self,
                userInfo: ["token": loginInfo?.token]
            )
        }

        if let temp = loginInfo {
            FTKv.shared.setup(uid: temp.userID)
            // ⚠️ 用 withoutPrefix("UserInfoKey") 存全局用户信息，key 是硬编码字符串，
            //   建议抽成 Key 枚举，避免拼写错误
            FTKv.shared.set(temp, forKey: .withoutPrefix("UserInfoKey"), isGlobal: true)
            //FTInfo.reloadCachedUserAddress()
            // 只有 updateNetConfig=true 才触发登录通知
            guard updateNetConfig else { return }
            for index in 0..<loginObservers.count {
                let observer = loginObservers.ft.object(at: index) as? GlobalEventable
                observer?.login()
            }
        } else {
            // 登出：移除全局用户信息
            FTKv.shared.remove(forKey: .withoutPrefix("UserInfoKey"), isGlobal: true)
        }
    }

    // MARK: - 用户资料

    /// 更新用户资料
    /// - Parameters:
    ///   - profileInfo: 用户数据
    ///   - type: 更新类型（普通/登录等）
    public func update(profileInfo: TMeGetData?, type: UserUpdateType = .normal) {
        guard let obj = profileInfo else { return }
        guard obj.userResource.id > 0 else {
       
            FTLog.error("invalid_user_identifier")
            return
        }
        if loginInfo?.userID == obj.userResource.id {
            // 是自己的资料，存到 .me key
            setObject(dataPb: obj, uidKey: .me, type: type)
        } else {
            // 是别人的资料，存到 user(uid) key
            let uidKey = FTKey.user(obj.userResource.id)
            setObject(dataPb: obj, uidKey: uidKey)
        }
    }

    /// 批量更新用户资料
    public func update(_ users: [TMeGetData]) {
        users.forEach { update(profileInfo: $0) }
    }

    /// 判断某个 uid 是否是自己
    public func isMe(uid: Int64) -> Bool {
        (profileInfo?.userResource.id ?? loginInfo?.userID) == uid
    }

    /// 获取指定用户信息
    /// - Parameter uid: 用户 id
    /// - Returns: 用户数据；uid 非法返回 nil
    public func getUserInfo(_ uid: Int64) -> TMeGetData? {
        guard uid > 0 else { return nil }
        if loginInfo?.userID == uid {
            return profileInfo
        } else {
            let uidKey = FTKey.user(uid)
            return FTKv.shared.value(TMeGetData.self, forKey: uidKey)
        }
    }

    // MARK: - private

    /// 合并写入用户数据（增量更新：只覆盖有值的子资源，保留旧值）
    /// - Parameters:
    ///   - obj: 新数据
    ///   - uidKey: 存储 key
    ///   - type: 更新类型
    private func setObject(dataPb obj: TMeGetData?, uidKey: FTKey, type: UserUpdateType = .normal) {
        guard let obj = obj else { return }

        /// 用新数据的"有效子资源"覆盖旧数据，无效的保留旧值
        func updatePb(oldPb: inout TMeGetData) -> TMeGetData {
            oldPb.userResource = obj.hasUserResource ? obj.userResource : oldPb.userResource
            oldPb.userProfileResource = obj.hasUserProfileResource ? obj.userProfileResource : oldPb.userProfileResource
            // ...（22 个子资源逐一合并，逻辑一致）
            return oldPb
        }

        // 读旧值 → 合并 → 得到新值
        let newPb: TMeGetData
        if var dataPb = FTKv.shared.value(TMeGetData.self, forKey: uidKey) {
            newPb = updatePb(oldPb: &dataPb)
        } else {
            newPb = obj
        }

        // 如果是自己的资料，更新内存中的 profileInfo 并通知
        if uidKey.name == FTKey.me.name {
            var tempInfo = profileInfo
            profileInfo = newPb
            meInfoUpdate(oldPb: tempInfo, newPb: newPb, type: type)
        }

        // 落盘
        FTKv.shared.set(newPb, forKey: uidKey)
    }

    /// 发出用户信息更新通知
    /// ⚠️ 问题：old 参数传的是 `profileInfo`（此时已被赋值为 newPb），
    ///   导致通知里的 old 和 new 实际相同，观察者拿不到真正的旧值
    func meInfoUpdate(oldPb: TMeGetData?, newPb: TMeGetData?, type: UserUpdateType) {
        for index in 0..<loginObservers.count {
            let observer = loginObservers.ft.object(at: index) as? GlobalEventable
            observer?.userInfoUpdate(old: profileInfo, new: newPb, type: type)
        }
    }

    /// 清除登录态（登出）
    public func clear() {
        profileInfo = nil
        loginInfo = nil
        update(loginInfo: nil)
        // 通知观察者登出
        for index in 0..<loginObservers.count {
            let observer = loginObservers.ft.object(at: index) as? GlobalEventable
            observer?.logout()
        }
    }
}

/// 构建环境类型
public enum BuildEevType: String {
    case appStoreEnv
    case debugEnv
    case inhouseEnv
    case internalEnv
}

/// FTInfo 的 OC 桥接（供 OC 代码获取 token）
@objc public class FTInfoOCObjectBridge: NSObject {
    @objc public static func getToken() -> String {
        let token = FTInfo.shared.loginInfo?.token ?? ""
        return token
    }
}
