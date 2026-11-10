//
//  FTInfo+User.swift
//  FTReq
//
//  Created by 熊坤鹏 on 2026/10/30.
//

import FTTool
import FTKv
import FTLogger
import FTReq
import RxSwift
import FTDb

// MARK: - 用户备注名

extension FTInfo {

    /// 获取用户展示名（有备注显示备注，无备注显示群昵称或昵称）
    /// - Parameters:
    ///   - uid: 用户 id
    ///   - groupId: 群 id（可选，用于查群内备注）
    /// - Returns: 展示名；用户信息不存在返回空串
    /// 优先级：用户备注 > 群内备注（需传 groupId）> 用户昵称
    public func userNoteName(uid: Int64, groupId: String = "") -> String {
        if let temp = getUserInfo(uid) {
            if !temp.userNoteResource.noteName.isEmpty {
                return temp.userNoteResource.noteName
            } else {
                if !groupId.isEmpty,
                   let temp = FTKv.shared.value(TGroupMembersGetData.self, forKey: .groupUser(uid, groupId)),
                   !temp.noteName.isEmpty {
                    return temp.noteName
                }
                return temp.userResource.firstName
            }
        }
        return ""
    }

    /// 获取用户展示名（支持外部传入群昵称，减少一次 KV 查询）
    /// - Parameters:
    ///   - uid: 用户 id
    ///   - groupNoteName: 外部已知的群昵称（非空时优先于本地群备注查询）
    ///   - groupId: 群 id（可选）
    /// - Returns: 展示名
    /// 优先级：用户备注 > 传入的 groupNoteName > 本地群内备注 > 用户昵称
    public func userNoteName(uid: Int64, groupNoteName: String, groupId: String = "") -> String {
        if let temp = getUserInfo(uid) {
            if !temp.userNoteResource.noteName.isEmpty {
                return temp.userNoteResource.noteName
            } else if groupNoteName.isEmpty == false {
                return groupNoteName
            } else {
                if !groupId.isEmpty,
                   let temp = FTKv.shared.value(TGroupMembersGetData.self, forKey: .groupUser(uid, groupId)),
                   !temp.noteName.isEmpty {
                    return temp.noteName
                }
                return temp.userResource.firstName
            }
        }
        return ""
    }

    // MARK: - 更新用户关注状态

    /// 更新用户关注状态
    /// - Parameters:
    ///   - uid: 用户 id
    ///   - status: 关注关系
    /// - Returns: 是否更新成功（用户信息不存在返回 false）
    /// ⚠️ 问题：userInfo 声明为 `var userInfo: TMeGetData?`，但它是值类型，
    ///   修改 userInfo?.xxx 后需要靠 update(profileInfo:) 落盘；
    ///   中间对 userInfo 的修改在值语义下是有效的（因为它是 var 局部副本），
    ///   但若 getUserInfo 返回的是引用（class）则修改会直接影响缓存，需确认 TMeGetData 是 struct。
    public func userStatusUpdate(uid: Int64, status: TFollowTypeFollowType) -> Bool {
        var userInfo: TMeGetData?
        if let temp = getUserInfo(uid) {
            userInfo = temp
            if temp.hasUserFollowingResource {
                userInfo?.userFollowingResource.status = status
            } else {
                var fol = TMeGetUserFollowingResource()
                fol.status = status
                userInfo?.userFollowingResource = fol
            }
            FTInfo.shared.update(profileInfo: userInfo)
            return true
        }
        return false
    }

    // MARK: - 更新用户备注名

    /// 更新用户备注名
    /// - Parameters:
    ///   - uid: 用户 id
    ///   - noteName: 新备注名
    /// - Returns: 是否更新成功
    public func userNoteNameUpdate(uid: Int64, noteName: String) -> Bool {
        if var temp = getUserInfo(uid) {
            if temp.hasUserNoteResource {
                temp.userNoteResource.noteName = noteName
            } else {
                var fri = TMeGetUserNoteResource()
                fri.noteName = noteName
                temp.userNoteResource = fri
            }
            FTInfo.shared.update(profileInfo: temp)
            return true
        }
        return false
    }

    // MARK: - 阅后即焚设置

    /// 设置会话的阅后即焚开关
    /// - Parameters:
    ///   - localConverId: 本地会话 id
    ///   - openBurn: 是否开启（1 开启 / 0 关闭）
    /// ⚠️ 用 Int 而非 Bool，取值语义靠约定；localConverId 为空时上报异常并打日志
    public func update(localConverId: String, openBurn: Int) {
        if !localConverId.isEmpty {
            FTKv.shared.set(openBurn, forKey: .general(localConverId + "_burn"))
        } else {
     
            FTLog.error("‼️‼️‼️‼️‼️‼️‼️ localConverId 为空")
        }
    }

    /// 读取会话的阅后即焚开关
    /// - Parameter localConverId: 本地会话 id
    /// - Returns: 1 开启 / 0 关闭（未设置或 id 为空时返回 0）
    public func burnSelect(localConverId: String) -> Int {
        if !localConverId.isEmpty {
            if let burn = FTKv.shared.value(Int.self, forKey: .general(localConverId + "_burn")) {
                return burn
            }
        }
        return 0
    }

    // MARK: - 群成员信息缓存

    /// 缓存群成员信息
    /// - Parameters:
    ///   - obj: 群成员数据
    ///   - userId: 用户 id
    ///   - groupId: 群 id
    /// 参数非法时静默返回
    public func setObject(groupUserData obj: TGroupMembersGetData?, userId: Int64, groupId: String) {
        guard let obj = obj, userId > 0, !groupId.isEmpty else { return }
        FTKv.shared.set(obj, forKey: FTKey.groupUser(userId, groupId))
    }

    // MARK: - 拉取我的信息

    /// 拉取当前用户的完整信息
    /// - Parameters:
    ///   - fields: 请求字段（逗号分隔）；为空时用默认字段集
    ///   - completion: 回调（用户数据 / 错误）
    public func getMeInfo(fields: String = "",
                          completion: ((_ info: TMeGetData?, _ err: NetworkError?) -> Void)?) {
        var reqFields = fields
        if reqFields.isEmpty {
            // 默认拉取常用子资源
            reqFields = "user,userSetting,userWallet,userCommon,userProfile,userFollowing,userUgcInfo,userAccount,userInvite,userExtra,userWeb3Assets"
        }
        let req = ContactRequest(apiType: .v1Me(fields: reqFields))
        NetworkManager.shared.normalRequest(apiConvertable: req, resType: TMeGetData.self) { res, error in
            completion?(res?.model, error)
        }
    }
}

// MARK: - 批量获取用户信息

extension FTInfo {

    /// 批量获取用户信息（回调版）
    /// - 内部通过 FTInfoRequestManager 做请求合并/去重，避免同一批 id 重复请求
    /// - Parameters:
    ///   - ids: 用户 id 列表
    ///   - success: 成功回调
    ///   - error: 失败回调
    ///
    /// ⚠️ 问题：
    ///   1. ids 为空时直接 success([])，但 error 回调永远不会触发，符合预期
    ///   2. FTInfoRequestManager.addRequest 的 completion 参数 value 为 false 时才真正发请求，
    ///      说明 manager 内部做了"是否已有人请求过"的判断，需确认其线程安全
    ///   3. 请求字段里 "friendInfo"、"userPrivacy" 等是否与 TMeGetData 的子资源名对应需确认
    public static func userGetRequest(
        ids: [Int64],
        success: @escaping (_ data: [TMeGetData]) -> Void,
        error: @escaping (_ error: Error) -> Void
    ) {
        guard !ids.isEmpty else { return success([]) }
        let idsArr = ids.filter({ $0 > 0 })
        FTInfoRequestManager.shared.addRequest(ids: idsArr, success: success, error: error, completion: { value in
            if value == false {
                let fields = "user, userAccount, userProfile, userSetting, friendInfo, userFollowing, aiRoleInfo, userNote, userBlock, userPrivacy, userVip, userAiClone"
                let req = ContactRequest(apiType: .v1User(ids: idsArr, fields: fields))
                NetworkManager.shared.send(req, resType: [TMeGetData].self) { res in
                    switch res {
                    case .success(let users):
                        FTInfo.shared.update(users)
                        FTInfoRequestManager.shared.success(ids: idsArr, value: users)
                    case .failure(let err):
                        FTInfoRequestManager.shared.failure(ids: idsArr, error: err)
                    }
                }
            }
        })
    }

    /// 批量获取用户信息（Observable 版）
    /// - Parameter ids: 用户 id 列表
    /// - Returns: 用户数据数组
    /// ⚠️ 注释已标明"并发有问题"：底层依赖 FTInfoRequestManager 的合并逻辑，
    ///   多线程同时调用时可能返回不完整数据（后到的调用可能拿到先到请求的结果子集）
    public static func userGetRequest(ids: [Int64]) -> Observable<[TMeGetData]> {
        return Observable.create { observer in
            guard !ids.isEmpty else {
                observer.onNext([])
                observer.onCompleted()
                return Disposables.create()
            }
            userGetRequest(ids: ids) { data in
                observer.onNext(data)
                observer.onCompleted()
            } error: { error in
                observer.onError(error)
            }
            return Disposables.create()
        }
    }

    /// 批量获取用户信息（Single 版，会话场景用）
    /// - Parameter ids: 用户 id 列表
    /// - Returns: 用户数据数组；失败时返回空数组（不抛错）
    /// ⚠️ 失败被吞成空数组：调用方无法区分"没有数据"与"请求失败"，
    ///   若后续需要区分，建议改为 single(.failure(error)) 或返回 Result
    public static func convoGetUserInfoRequest(ids: [Int64]) -> Single<[TMeGetData]> {
        return Single.create { single in
            guard !ids.isEmpty else {
                single(.success([]))
                return Disposables.create()
            }
            userGetRequest(ids: ids) { data in
                single(.success(data))
            } error: { error in
                single(.success([]))   // ⚠️ 失败吞成空数组
            }
            return Disposables.create()
        }
    }

    /// 本地没有的用户才请求后台
    /// - Parameter ids: 用户 id 列表
    /// - Returns: 拉取到的用户数据
    /// 先过滤出本地未缓存的 id，没有则直接返回空
    public static func getUsersIfNotInDb(ids: [Int64]) -> Observable<[TMeGetData]> {
        let filterIds = ids.filter { $0 > 0 && FTInfo.shared.getUserInfo($0) == nil }
        guard !filterIds.isEmpty else {
            return Observable.just([])
        }
        return userGetRequest(ids: filterIds)
    }

    // MARK: - 从消息内容取用户信息

    /// 从消息 content 的 ext 里取 userId 并返回其展示名
    /// - Parameters:
    ///   - contentBody: 消息内容
    ///   - extStr: ext 里存 userId 的 key
    ///   - groupId: 群 id（用于查群昵称）
    ///   - canReturnUid: 名称为空时是否回退到 uid 字符串
    public static func getUserName(contentBody: TMessageCheckConversationPostReq,
                                   extStr: String,
                                   groupId: String = "",
                                   canReturnUid: Bool = true) -> String {
        let userId = FTDb.shared.getUserId(contentBody: contentBody, extStr: extStr)
        var userNoteName = FTInfo.shared.userNoteName(uid: userId, groupId: groupId)
        if userNoteName.isEmpty && canReturnUid {
            userNoteName = "\(userId)"
        }
        return userNoteName
    }

    /// 从消息 content 的 ext 里取 userId 列表
    /// - Parameters:
    ///   - contentBody: 消息内容
    ///   - extStr: ext 里存 userId 列表的 key
    /// - Returns: 有效 userId 列表
    /// ⚠️ 内部用 map 遍历但只为副作用（append），应改用 forEach；
    ///   且外层 `var users` 未初始化容量，可 reserveCapacity 提升效率
    public static func getUserIds(contentBody: TMessageCheckConversationPostReq, extStr: String) -> [Int64] {
        var users: [Int64] = [Int64]()
        if let memberList = contentBody.ext[extStr] as? [Int64], !memberList.isEmpty {
            let list = memberList.map({ userId in
                if userId > 0 {
                    users.append(userId)
                }
            })
            // ⚠️ `let list = ...` 未使用，map 的返回值被丢弃
        }
        return users
    }

    /// 判断消息内容里的发送者是否是自己
    /// - Parameters:
    ///   - contentBody: 消息内容
    ///   - extStr: ext 里存发送者 id 的 key
    /// - Returns: 是否为自己
    /// ⚠️ 三个分支逻辑有重叠：
    ///   分支 2 和分支 3 都在处理 String 类型的 senderId，
    ///   且分支 3 的前置条件（temp 非空 + 转 Int64 成功）已被分支 2 覆盖，
    ///   实际上分支 3 是死代码，建议合并精简
    public static func isMe(contentBody: TMessageCheckConversationPostReq, extStr: String) -> Bool {
        let tmpSenderId: Int64? = contentBody.ext[key: extStr]
        if let senderId = tmpSenderId, senderId > 0 {
            if senderId == FTInfo.shared.profileInfo?.userResource.id {
                return true
            }
        } else if let senderString = contentBody.ext[extStr] as? String,
                  let sender = Int64(senderString), sender > 0 {
            if sender == FTInfo.shared.profileInfo?.userResource.id {
                return true
            }
        } else if let temp = contentBody.ext[extStr] as? String,
                  !temp.isEmpty,
                  let senderId = Int64(temp),
                  senderId > 0,
                  senderId == FTInfo.shared.profileInfo?.userResource.id {
            return true
        }
        return false
    }

    // MARK: - 收集消息涉及的用户

    /// 根据消息内容收集需要补请求的用户 id
    /// - Parameters:
    ///   - msgM: 消息
    ///   - uidSet: 待补充的 uid 集合（inout，会去重追加）
    /// 逻辑：按消息类型解析 ext 里的用户字段，收集本地未缓存的 uid
    // swiftlint:disable cyclomatic_complexity
    private static func getMsgUserInfo(msgM: IMMessage, uidSet: inout Set<Int64>) {
        if msgM.uid > 0 && msgM.type == IMMessageType.textMessage.rawValue && FTInfo.shared.getUserInfo(msgM.uid) == nil {
            uidSet.insert(msgM.uid)
        } else if msgM.type == IMMessageType.systemMessage.rawValue {
            guard var contentBody = msgM.contentBody else { return }
            // 兼容 receive_id / receiver_id 两种 key
            if contentBody.ext["receive_id"] == nil, contentBody.ext["receiver_id"] != nil {
                contentBody.ext["receive_id"] = contentBody.ext["receiver_id"]
            }

            // 先收集到局部集合，最后统一过滤后加入 uidSet（避免提前过滤影响同一条消息内的去重）
            var pendingUids = Set<Int64>()

            switch contentBody.type {
            case .newMember:
                // 新成员 + 邀请人
                let memberUid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "user_id")
                if memberUid > 0 { pendingUids.insert(memberUid) }
                let inviterUid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "invite_user_id")
                if inviterUid > 0 { pendingUids.insert(inviterUid) }

            case .newGroup:
                // 创建群：群主 + 成员列表
                let masterUid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "master_id")
                if masterUid > 0 { pendingUids.insert(masterUid) }
                if let memberList = contentBody.ext["member_list"] as? [Int64], !memberList.isEmpty {
                    memberList.forEach { pendingUids.insert($0) }
                }

            case .groupQuit:
                let uid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "userId")
                if uid > 0 { pendingUids.insert(uid) }

            case .groupKickOut:
                // 被踢的人（user_id）+ 操作者（senderID）
                let kickUid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "user_id")
                if kickUid > 0 { pendingUids.insert(kickUid) }
                let senderId = contentBody.senderID
                if senderId > 0 { pendingUids.insert(senderId) }

            case .userRefuseToJoinGroup:
                if let memberList = contentBody.ext["refused_user_ids"] as? [Int64], !memberList.isEmpty {
                    memberList.forEach { pendingUids.insert($0) }
                }

            case .scrambleRedPacket, .scrambleRedPacketV2:
                let receiverId = FTDb.shared.getUserId(contentBody: contentBody, extStr: "receive_id")
                if receiverId > 0 { pendingUids.insert(receiverId) }
                let senderId = FTDb.shared.getUserId(contentBody: contentBody, extStr: "sender_id")
                if senderId > 0 { pendingUids.insert(senderId) }

            case .groupNewCall:
                let senderId = contentBody.senderID
                if senderId > 0 { pendingUids.insert(senderId) }

            case .newLeader, .removeLeader:
                let uid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "user_id")
                if uid > 0 { pendingUids.insert(uid) }

            case .groupTransferMaster:
                let uid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "user_id")
                if uid > 0 { pendingUids.insert(uid) }

            case .groupModifyName:
                let uid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "userId")
                if uid > 0 { pendingUids.insert(uid) }

            case .groupInviteTitle:
                let uid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "userId")
                if uid > 0 { pendingUids.insert(uid) }

            case .patMessage:
                // 拍一拍：发起者 + 被拍者
                let fromUid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "fromUid")
                if fromUid > 0 { pendingUids.insert(fromUid) }
                let toUid = FTDb.shared.getUserId(contentBody: contentBody, extStr: "toUid")
                if toUid > 0 { pendingUids.insert(toUid) }
                // 撤回场景下的消息发送者
                if msgM.uid > 0 { pendingUids.insert(msgM.uid) }

            default:
                break
            }

            // 统一过滤：本地已缓存的不重复请求
            for uid in pendingUids where FTInfo.shared.getUserInfo(uid) == nil {
                uidSet.insert(uid)
            }
        }
    }

    /// 批量拉取历史消息涉及的用户信息
    /// - Parameters:
    ///   - messages: 历史消息
    ///   - res: 回调（成功/失败）
    /// ⚠️ 问题：
    ///   1. `messages.map { ... }` 只为副作用（修改 uidSet），应改用 forEach
    ///   2. `uidSet.insert(msgM.uid)` 无条件插入，未过滤 uid <= 0，
    ///      会把 uid=0 也加入请求（虽然后续 userGetRequest 里 filter 掉，但多一次无谓处理）
    ///   3. 失败回调只打日志，未上报监控
    public static func getHistoryMsgUserInfo(messages: [IMMessage], res: @escaping (_ suc: Bool) -> Void) {
        var uidSet = Set<Int64>()
        messages.map { msgM in
            FTInfo.getMsgUserInfo(msgM: msgM, uidSet: &uidSet)
            uidSet.insert(msgM.uid)   // ⚠️ 未过滤 uid <= 0
        }
        if !uidSet.isEmpty {
            let uidArr = Array(uidSet)
            FTInfo.userGetRequest(ids: uidArr) { _ in
                res(true)
            } error: { err in
                res(false)
                FTLog.error("TTChat get user info failed")   // ⚠️ 未上报监控
            }
        }
    }
}

// MARK: - 用户地址缓存

extension FTInfo {

    /// 更新缓存的用户地址
    /// - Parameter model: 地址数据
    /// - Returns: 是否成功
    /// 成功后会：写 KV、更新网络配置的 adcode、通知 Flutter 更新
//    public static func updateCachedUserAddress(_ model: QueryUserAddressResData?) -> Bool {
//        guard let model = model else { return false }
//        guard let data = model.tottDict else {
//        
//            FTLog.debug("model_encoding_failed")
//            return false
//        }
//
//        FTKv.shared.set(data, forKey: FTKey.currentUsedAddress)
//
//        // 拼接 adcode：省_市_区_街道
//        let adcode = "\(model.provinceCode ?? "")_\(model.cityCode ?? "")_\(model.districtCode ?? "")_\(model.townCode ?? "")"
//
//        FTKv.shared.set(adcode, forKey: .withoutPrefix("kADCode"), isGlobal: true)
//        NetworkManager.shared.updateConfig(with: [
//            \.adcode: adcode
//        ])
//        // 通知 Flutter 更新 adcode
//        NotificationCenter.default.post(
//            name: FTReqNotifiName.updateAdCode.name,
//            object: self,
//            userInfo: ["adCode": adcode]
//        )
//
//        FTLog.debug("Update cached user address")
//        return true
//    }

    /// 重新加载缓存的用户地址（缓存缺失/无效时请求服务端补全）
    /// 逻辑：
    ///   1. 读 KV 里的地址缓存，能解码且 addressId 非空 → 直接用，不再请求
    ///   2. 缓存缺失/无效 → 请求服务端
    ///   3. 服务端返回：空列表 → 用北京默认地址；单条 → 直接用；多条 → 优先默认地址
//    public static func reloadCachedUserAddress() {
//        if let data = FTKv.shared.value([String: Any].self, forKey: FTKey.currentUsedAddress), data.isEmpty == false {
//            do {
//                let jsonData = try JSONSerialization.data(withJSONObject: data)
//                let model = try JSONDecoder().decode(QueryUserAddressResData.self, from: jsonData)
//                if model.addressId != nil {
//                    FTLog.debug("Found existing address cache data")
//                    return
//                }
//            
//                FTLog.debug("address_identifier_missing")
//            } catch {
//              
//                FTLog.debug("cached_model_decode_failed")
//            }
//        } else {
//            FTLog.debug("No address cache found")
//        }
//
//        // 缓存无效 → 请求服务端
//        let req = HouseRequest(apiType: .queryUserAddress, hudConfig: nil)
//
//        NetworkManager.shared.send(req, resType: [String: [QueryUserAddressResData]].self) { res in
//            switch res {
//            case .success(let suc):
//                if let items = suc["userAddressList"] {
//                    if items.isEmpty {
//                        // 空列表 → 用北京朝阳默认地址兜底
//                        var reserved = QueryUserAddressResData()
//                        reserved.provinceCode = "11000000"
//                        reserved.provinceName = "北京"
//                        reserved.cityCode = "11010000"
//                        reserved.cityName = "北京市"
//                        reserved.districtCode = "11010200"
//                        reserved.districtName = "朝阳区"
//                        reserved.townCode = "110102002"
//                        reserved.townName = "朝外街道"
//                        updateCachedUserAddress(reserved)
//                    } else if items.count == 1 {
//                        updateCachedUserAddress(items.first)
//                    } else {
//                        // 多条 → 优先默认地址，否则取第一条
//                        let defaultItem = items.first { $0.isDefault == true }
//                        updateCachedUserAddress(defaultItem ?? items.first)
//                    }
//                } else {
//              
//                    FTLog.error("address_refresh")
//                }
//            case .failure(let err):
//                FTLog.error(err)
//            }
//        }
//    }
}
