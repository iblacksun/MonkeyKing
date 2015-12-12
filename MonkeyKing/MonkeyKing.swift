//
//  MonkeyKing.swift
//  MonkeyKing
//
//  Created by NIX on 15/9/11.
//  Copyright © 2015年 nixWork. All rights reserved.
//

import UIKit
import WebKit

public func ==(lhs: MonkeyKing.Account, rhs: MonkeyKing.Account) -> Bool {
    return lhs.appID == rhs.appID
}

public class MonkeyKing: NSObject {

    private static let sharedMonkeyKing = MonkeyKing()

    public typealias SharedCompletionHandler = (result: Bool) -> Void

    private var sharedCompletionHandler: SharedCompletionHandler?
    private var accountSet = Set<Account>()
    private var OAuthCompletionHandler: MKGNetworkingResponseHandler?

    // Prevent others from using the default '()' initializer for MonkeyKing.
    private override init() {}

    public enum Account: Hashable {

        case WeChat(appID: String, appKey: String?)
        case QQ(appID: String)
        case Weibo(appID: String, appKey: String, redirectURL: String)
        case Pocket(appID: String)

        public var isAppInstalled: Bool {
            switch self {
            case .WeChat:
                return sharedMonkeyKing.canOpenURL(URLString: "weixin://")
            case .QQ:
                return sharedMonkeyKing.canOpenURL(URLString: "mqqapi://")
            case .Weibo:
                return sharedMonkeyKing.canOpenURL(URLString: "weibosdk://request")
            case .Pocket:
                return sharedMonkeyKing.canOpenURL(URLString: "pocket-oauth-v1://")
            }
        }

        public var appID: String {
            switch self {
            case .WeChat(let appID, _):
                return appID
            case .QQ(let appID):
                return appID
            case .Weibo(let appID, _, _):
                return appID
            case .Pocket(let appID):
                return appID
            }
        }

        public var hashValue: Int {
            return appID.hashValue
        }

        public var canWebOAuth: Bool {
            switch self {
            case .QQ, .Weibo, .Pocket:
                return true
            default:
                return false
            }
        }
    }

    public class func registerAccount(account: Account) {

        if account.isAppInstalled || account.canWebOAuth {

            for oldAccount in MonkeyKing.sharedMonkeyKing.accountSet {

                switch oldAccount {

                case .WeChat:
                    if case .WeChat = account {
                        sharedMonkeyKing.accountSet.remove(oldAccount)
                    }
                case .QQ:
                    if case .QQ = account {
                        sharedMonkeyKing.accountSet.remove(oldAccount)
                    }
                case .Weibo:
                    if case .Weibo = account {
                        sharedMonkeyKing.accountSet.remove(oldAccount)
                    }
                case .Pocket:
                    if case .Pocket = account {
                        sharedMonkeyKing.accountSet.remove(oldAccount)
                    }
                }
            }

            sharedMonkeyKing.accountSet.insert(account)
        }
    }
}


// MARK: OpenURL Handler

extension MonkeyKing {

    public class func handleOpenURL(URL: NSURL) -> Bool {

        if URL.scheme.hasPrefix("wx") {

            // WeChat OAuth
            if URL.absoluteString.containsString("&state=Weixinauth") {

                let queryItems = URL.monkeyking_queryItems
                guard let code = queryItems["code"] as? String else {
                    return false
                }

                // Login Succcess
                fetchWeChatOAuthInfoByCode(code: code) { (info, response, error) -> Void in
                    sharedMonkeyKing.OAuthCompletionHandler?(info, response, error)
                }

                return true
            }

            // WeChat Share
            guard let data = UIPasteboard.generalPasteboard().dataForPasteboardType("content") else {
                return false
            }

            if let dic = try? NSPropertyListSerialization.propertyListWithData(data, options: .Immutable, format: nil) {

                guard let account = sharedMonkeyKing.accountSet[.WeChat],
                    dic = dic[account.appID] as? NSDictionary,
                    result = dic["result"]?.integerValue else {
                        return false
                }

                let success = (result == 0)
                sharedMonkeyKing.sharedCompletionHandler?(result: success)

                return success
            }
        }

        // QQ Share
        if URL.scheme.hasPrefix("QQ") {

            guard let error = URL.monkeyking_queryItems["error"] as? String else {
                return false
            }

            let success = (error == "0")

            sharedMonkeyKing.sharedCompletionHandler?(result: success)

            return success
        }

        // QQ OAuth
        if URL.scheme.hasPrefix("tencent") {

            guard let account = sharedMonkeyKing.accountSet[.QQ] else {
                return false
            }

            var userInfoDictionary: NSDictionary?
            var error: NSError?

            defer {
                sharedMonkeyKing.OAuthCompletionHandler?(userInfoDictionary, nil, error)
            }

            guard let data = UIPasteboard.generalPasteboard().dataForPasteboardType("com.tencent.tencent\(account.appID)"),
                let dic = NSKeyedUnarchiver.unarchiveObjectWithData(data) as? NSDictionary else {
                    error = NSError(domain: "OAuth Error", code: -1, userInfo: nil)
                    return false
            }

            guard let result = dic["ret"]?.integerValue where result == 0 else {
                if let errorDomatin = dic["user_cancelled"] as? String where errorDomatin == "YES" {
                    error = NSError(domain: "User Cancelled", code: -2, userInfo: nil)
                } else {
                    error = NSError(domain: "OAuth Error", code: -1, userInfo: nil)
                }
                return false
            }

            userInfoDictionary = dic

            return true
        }

        // Weibo
        if URL.scheme.hasPrefix("wb") {

            guard let items = UIPasteboard.generalPasteboard().items as? [[String: AnyObject]] else {
                return false
            }

            var results = [String: AnyObject]()

            for item in items {
                for (key, value) in item {
                    if let valueData = value as? NSData where key == "transferObject" {
                        results[key] = NSKeyedUnarchiver.unarchiveObjectWithData(valueData)
                    }
                }
            }

            guard let responseData = results["transferObject"] as? [String: AnyObject],
                let type = responseData["__class"] as? String else {
                    return false
            }

            guard let statusCode = responseData["statusCode"] as? Int else {
                return false
            }

            switch type {

                // Weibo OAuth
            case "WBAuthorizeResponse":

                var userInfoDictionary: NSDictionary?
                var error: NSError?

                defer {
                    sharedMonkeyKing.OAuthCompletionHandler?(responseData, nil, error)
                }

                userInfoDictionary = responseData

                if statusCode != 0 {
                    error = NSError(domain: "OAuth Error", code: -1, userInfo: nil)
                    return false
                }
                return true

                // Weibo Share
            case "WBSendMessageToWeiboResponse":

                let success = (statusCode == 0)
                sharedMonkeyKing.sharedCompletionHandler?(result: success)
                
                return success
                
            default:
                break
            }
            
        }
        
        // Pocket OAuth
        if URL.scheme.hasPrefix("pocketapp") {
            sharedMonkeyKing.OAuthCompletionHandler?(nil, nil, nil)
            return true
        }
        
        return false
    }
}


// MARK: Share Message

extension MonkeyKing {

    public enum Media {

        case URL(NSURL)
        case Image(UIImage)
        case ImageURL(NSURL)
        case Audio(audioURL: NSURL, linkURL: NSURL?)
        case Video(NSURL)
    }

    public typealias Info = (title: String?, description: String?, thumbnail: UIImage?, media: Media?)

    public enum Message {

        public enum WeChatSubtype {

            case Session(info: Info)
            case Timeline(info: Info)

            var scene: String {
                switch self {
                case .Session:
                    return "0"
                case .Timeline:
                    return "1"
                }
            }

            var info: Info {
                switch self {
                case .Session(let info):
                    return info
                case .Timeline(let info):
                    return info
                }
            }
        }
        case WeChat(WeChatSubtype)

        public enum QQSubtype {
            case Friends(info: Info)
            case Zone(info: Info)

            var scene: Int {
                switch self {
                case .Friends:
                    return 0
                case .Zone:
                    return 1
                }
            }

            var info: Info {
                switch self {
                case .Friends(let info):
                    return info
                case .Zone(let info):
                    return info
                }
            }
        }
        case QQ(QQSubtype)

        public enum WeiboSubtype {
            case Default(info: Info, accessToken: String?)

            var info: Info {
                switch self {
                case .Default(let info, _):
                    return info
                }
            }

            var accessToken: String? {
                switch self {
                case .Default(_, let accessToken):
                    return accessToken
                }
            }
        }
        case Weibo(WeiboSubtype)

        public var canBeDelivered: Bool {

            guard let account = sharedMonkeyKing.accountSet[self] else {
                return false
            }

            if case .Weibo = account {
                return true
            }
            
            return account.isAppInstalled
        }
    }

    public class func shareMessage(message: Message, completionHandler: SharedCompletionHandler) {

        guard message.canBeDelivered else {
            completionHandler(result: false)
            return
        }

        sharedMonkeyKing.sharedCompletionHandler = completionHandler

        guard let account = sharedMonkeyKing.accountSet[message] else {
            completionHandler(result: false)
            return
        }

        let appID = account.appID

        switch message {

        case .WeChat(let type):

            var weChatMessageInfo: [String: AnyObject] = [
                "result": "1",
                "returnFromApp": "0",
                "scene": type.scene,
                "sdkver": "1.5",
                "command": "1010",
            ]

            let info = type.info

            if let title = info.title {
                weChatMessageInfo["title"] = title
            }

            if let description = info.description {
                weChatMessageInfo["description"] = description
            }

            if let thumbnailData = info.thumbnail?.monkeyking_compressedImageData {
                weChatMessageInfo["thumbData"] = thumbnailData
            }

            if let media = info.media {
                switch media {

                case .URL(let URL):
                    weChatMessageInfo["objectType"] = "5"
                    weChatMessageInfo["mediaUrl"] = URL.absoluteString

                case .Image(let image):
                    weChatMessageInfo["objectType"] = "2"

                    if let fileImageData = UIImageJPEGRepresentation(image, 1) {
                        weChatMessageInfo["fileData"] = fileImageData
                    }

                case .ImageURL(let URL):
                    assert(type.scene == "0", "Image URL type is only supported by WeChat Session")
                    assert(!URL.isFileReferenceURL(), "Should be a remote URL")
                    weChatMessageInfo["objectType"] = "2"
                    weChatMessageInfo["mediaUrl"] = URL.absoluteString

                case .Audio(let audioURL, let linkURL):
                    weChatMessageInfo["objectType"] = "3"

                    if let linkURL = linkURL {
                        weChatMessageInfo["mediaUrl"] = linkURL.absoluteString
                    }

                    weChatMessageInfo["mediaDataUrl"] = audioURL.absoluteString

                case .Video(let URL):
                    weChatMessageInfo["objectType"] = "4"
                    weChatMessageInfo["mediaUrl"] = URL.absoluteString
                }

            } else { // Text Share
                weChatMessageInfo["command"] = "1020"
            }

            let weChatMessage = [appID: weChatMessageInfo]

            guard let data = try? NSPropertyListSerialization.dataWithPropertyList(weChatMessage, format: .BinaryFormat_v1_0, options: 0) else {
                return
            }

            UIPasteboard.generalPasteboard().setData(data, forPasteboardType: "content")

            let weChatSchemeURLString = "weixin://app/\(appID)/sendreq/?"

            if !openURL(URLString: weChatSchemeURLString) {
                completionHandler(result: false)
            }

        case .QQ(let type):

            let callbackName = appID.monkeyking_QQCallbackName

            var qqSchemeURLString = "mqqapi://share/to_fri?"
            if let encodedAppDisplayName = NSBundle.mainBundle().monkeyking_displayName?.monkeyking_base64EncodedString {
                qqSchemeURLString += "thirdAppDisplayName=" + encodedAppDisplayName
            } else {
                qqSchemeURLString += "thirdAppDisplayName=" + "nixApp" // Should not be there
            }

            qqSchemeURLString += "&version=1&cflag=\(type.scene)"
            qqSchemeURLString += "&callback_type=scheme&generalpastboard=1"
            qqSchemeURLString += "&callback_name=\(callbackName)"

            qqSchemeURLString += "&src_type=app&shareType=0&file_type="

            if let media = type.info.media {

                func handleNewsWithURL(URL: NSURL, mediaType: String?) {

                    if let thumbnail = type.info.thumbnail, thumbnailData = UIImageJPEGRepresentation(thumbnail, 1) {
                        let dic = ["previewimagedata": thumbnailData]
                        let data = NSKeyedArchiver.archivedDataWithRootObject(dic)
                        UIPasteboard.generalPasteboard().setData(data, forPasteboardType: "com.tencent.mqq.api.apiLargeData")
                    }

                    qqSchemeURLString += mediaType ?? "news"

                    guard let encodedURLString = URL.absoluteString.monkeyking_base64AndURLEncodedString else {
                        completionHandler(result: false)
                        return
                    }

                    qqSchemeURLString += "&url=\(encodedURLString)"
                }

                switch media {

                case .URL(let URL):

                    handleNewsWithURL(URL, mediaType: "news")

                case .Image(let image):

                    guard let imageData = UIImageJPEGRepresentation(image, 1) else {
                        completionHandler(result: false)
                        return
                    }

                    var dic = [
                        "file_data": imageData,
                    ]
                    if let thumbnail = type.info.thumbnail, thumbnailData = UIImageJPEGRepresentation(thumbnail, 1) {
                        dic["previewimagedata"] = thumbnailData
                    }

                    let data = NSKeyedArchiver.archivedDataWithRootObject(dic)

                    UIPasteboard.generalPasteboard().setData(data, forPasteboardType: "com.tencent.mqq.api.apiLargeData")

                    qqSchemeURLString += "img"

                case .ImageURL(_):
                    fatalError("QQ not supports image URL type")

                case .Audio(let audioURL, _):
                    handleNewsWithURL(audioURL, mediaType: "audio")

                case .Video(let URL):
                    handleNewsWithURL(URL, mediaType: nil) // 没有 video 类型，默认用 news
                }

                if let encodedTitle = type.info.title?.monkeyking_base64AndURLEncodedString {
                    qqSchemeURLString += "&title=\(encodedTitle)"
                }

                if let encodedDescription = type.info.description?.monkeyking_base64AndURLEncodedString {
                    qqSchemeURLString += "&objectlocation=pasteboard&description=\(encodedDescription)"
                }

            } else { // Share Text
                qqSchemeURLString += "text&file_data="

                if let encodedDescription = type.info.description?.monkeyking_base64AndURLEncodedString {
                    qqSchemeURLString += "\(encodedDescription)"
                }
            }

            if !openURL(URLString: qqSchemeURLString) {
                completionHandler(result: false)
            }

        case .Weibo(let type):

            guard !sharedMonkeyKing.canOpenURL(URLString: "weibosdk://request") else {

                // App Share

                var messageInfo: [String: AnyObject] = ["__class": "WBMessageObject"]
                let info = type.info

                if let description = info.description {
                    messageInfo["text"] = description
                }

                if let media = info.media {
                    switch media {
                    case .URL(let URL):

                        var mediaObject: [String: AnyObject] = [
                            "__class": "WBWebpageObject",
                            "objectID": "identifier1"
                        ]

                        if let title = info.title {
                            mediaObject["title"] = title
                        }

                        if let thumbnailImage = info.thumbnail,
                            let thumbnailData = UIImageJPEGRepresentation(thumbnailImage, 0.7) {
                                mediaObject["thumbnailData"] = thumbnailData
                        }

                        mediaObject["webpageUrl"] = URL.absoluteString

                        messageInfo["mediaObject"] = mediaObject

                    case .Image(let image):

                        if let imageData = UIImageJPEGRepresentation(image, 1.0) {
                            messageInfo["imageObject"] = ["imageData": imageData]
                        }

                    case .ImageURL(_):
                        fatalError("Weibo not supports image URL type")

                    case .Audio:
                        fatalError("Weibo not supports Audio type")

                    case .Video:
                        fatalError("Weibo not supports Video type")
                    }
                }

                let uuIDString = CFUUIDCreateString(nil, CFUUIDCreate(nil))
                let dict = ["__class" : "WBSendMessageToWeiboRequest", "message": messageInfo, "requestID" :uuIDString]

                let messageData: [AnyObject] = [
                    ["transferObject": NSKeyedArchiver.archivedDataWithRootObject(dict)],
                    ["userInfo": NSKeyedArchiver.archivedDataWithRootObject([])],
                    ["app": NSKeyedArchiver.archivedDataWithRootObject(["appKey": appID, "bundleID": NSBundle.mainBundle().monkeyking_bundleID ?? ""])]
                ]

                UIPasteboard.generalPasteboard().items = messageData

                if !openURL(URLString: "weibosdk://request?id=\(uuIDString)&sdkversion=003013000") {
                    completionHandler(result: false)
                }

                return
            }

            // Weibo Web Share

            let info = type.info
            var parameters = [String: AnyObject]()

            guard let accessToken = type.accessToken else {
                print("When Weibo did not install, accessToken must need")
                completionHandler(result: false)
                return
            }

            parameters["access_token"] = accessToken

            var statusText = ""

            if let title = info.title {
                statusText += title
            }

            if let description = info.description {
                statusText += description
            }

            var mediaType = Media.URL(NSURL())

            if let media = info.media {

                switch media {

                case .URL(let URL):

                    statusText += URL.absoluteString

                    mediaType = Media.URL(URL)

                case .Image(let image):

                    guard let imageData = UIImageJPEGRepresentation(image, 0.7) else {
                        completionHandler(result: false)
                        return
                    }

                    parameters["pic"] = imageData
                    mediaType = Media.Image(image)

                case .ImageURL(_):
                    fatalError("web Weibo not supports image URL type")

                case .Audio:
                    fatalError("web Weibo not supports Audio type")

                case .Video:
                    fatalError("web Weibo not supports Video type")
                }
            }

            parameters["status"] = statusText
            
            switch mediaType {
                
            case .URL(_):
                
                let URLString = "https://api.weibo.com/2/statuses/update.json"
                
                sharedMonkeyKing.request(URLString, method: .POST, parameters: parameters) { (responseData, HTTPResponse, error) -> Void in
                    if let JSON = responseData, let _ = JSON["idstr"] as? String {
                        completionHandler(result: true)
                    } else {
                        print("responseData \(responseData) HTTPResponse \(HTTPResponse)")
                        completionHandler(result: false)
                    }
                }
                
            case .Image(_):
                
                let URLString = "https://upload.api.weibo.com/2/statuses/upload.json"
                
                sharedMonkeyKing.upload(URLString, parameters: parameters) { (responseData, HTTPResponse, error) -> Void in
                    if let JSON = responseData, let _ = JSON["idstr"] as? String {
                        completionHandler(result: true)
                    } else {
                        print("responseData \(responseData) HTTPResponse \(HTTPResponse)")
                        completionHandler(result: false)
                    }
                }
                
            case .ImageURL(_):
                fatalError("web Weibo not supports image URL type")
                
            case .Audio:
                fatalError("web Weibo not supports Audio type")
                
            case .Video:
                fatalError("web Weibo not supports Video type")
            }
            
        }
    }
}


// MARK: OAuth

extension MonkeyKing {

    public enum OAuthPlatform {
        case QQ
        case WeChat
        case Weibo
        case Pocket(requestToken: String)
    }

    public class func OAuth(platform: OAuthPlatform, scope: String? = nil, completionHandler: MKGNetworkingResponseHandler) {

        guard let account = sharedMonkeyKing.accountSet[platform] else {
            return
        }

        guard account.isAppInstalled || account.canWebOAuth else {
            let error = NSError(domain: "App is not installed", code: -2, userInfo: nil)
            completionHandler(nil, nil, error)
            return
        }

        sharedMonkeyKing.OAuthCompletionHandler = completionHandler

        switch account {

        case .WeChat(let appID, _):

            let scope = scope ?? "snsapi_userinfo"
            openURL(URLString: "weixin://app/\(appID)/auth/?scope=\(scope)&state=Weixinauth")

        case .QQ(let appID):

            let scope = scope ?? ""
            guard !account.isAppInstalled else {
                let appName = NSBundle.mainBundle().monkeyking_displayName ?? "nixApp"
                let dic = ["app_id": appID,
                    "app_name": appName,
                    "client_id": appID,
                    "response_type": "token",
                    "scope": scope,
                    "sdkp": "i",
                    "sdkv": "2.9",
                    "status_machine": UIDevice.currentDevice().model,
                    "status_os": UIDevice.currentDevice().systemVersion,
                    "status_version": UIDevice.currentDevice().systemVersion]

                let data = NSKeyedArchiver.archivedDataWithRootObject(dic)
                UIPasteboard.generalPasteboard().setData(data, forPasteboardType: "com.tencent.tencent\(appID)")

                openURL(URLString: "mqqOpensdkSSoLogin://SSoLogin/tencent\(appID)/com.tencent.tencent\(appID)?generalpastboard=1")

                return
            }

            // Web OAuth

            let accessTokenAPI = "http://xui.ptlogin2.qq.com/cgi-bin/xlogin?appid=716027609&pt_3rd_aid=209656&style=35&s_url=http%3A%2F%2Fconnect.qq.com&refer_cgi=m_authorize&client_id=\(appID)&redirect_uri=auth%3A%2F%2Fwww.qq.com&response_type=token&scope=\(scope)"
            addWebViewByURLString(accessTokenAPI)

        case .Weibo(let appID, _, let redirectURL):

            let scope = scope ?? "all"

            guard !account.isAppInstalled else {
                let uuIDString = CFUUIDCreateString(nil, CFUUIDCreate(nil))
                let authData = [
                    ["transferObject": NSKeyedArchiver.archivedDataWithRootObject(["__class": "WBAuthorizeRequest", "redirectURI": redirectURL, "requestID":uuIDString, "scope": scope])
                    ],
                    ["userInfo": NSKeyedArchiver.archivedDataWithRootObject(["mykey": "as you like", "SSO_From": "SendMessageToWeiboViewController"])],
                    ["app": NSKeyedArchiver.archivedDataWithRootObject(["appKey": appID, "bundleID": NSBundle.mainBundle().monkeyking_bundleID ?? "", "name": NSBundle.mainBundle().monkeyking_displayName ?? ""])]
                ]

                UIPasteboard.generalPasteboard().items = authData
                openURL(URLString: "weibosdk://request?id=\(uuIDString)&sdkversion=003013000")
                return
            }

            // Web OAuth
            let accessTokenAPI = "https://open.weibo.cn/oauth2/authorize?client_id=\(appID)&response_type=code&redirect_uri=\(redirectURL)&scope=\(scope)"
            addWebViewByURLString(accessTokenAPI)

        case .Pocket(let appID):

            guard let startIndex = appID.rangeOfString("-")?.startIndex else {
                return
            }
            let prefix = appID.substringToIndex(startIndex)
            let redirectURLString = "pocketapp\(prefix):authorizationFinished"

            var _requestToken: String?
            if case .Pocket(let token) = platform {
                _requestToken = token
            }

            guard let requestToken = _requestToken else {
                return
            }

            guard !account.isAppInstalled else {
                let requestTokenAPI = "pocket-oauth-v1:///authorize?request_token=\(requestToken)&redirect_uri=\(redirectURLString)"
                openURL(URLString: requestTokenAPI)
                return
            }

            let requestTokenAPI = "https://getpocket.com/auth/authorize?request_token=\(requestToken)&redirect_uri=\(redirectURLString)"
            dispatch_async(dispatch_get_main_queue()) {
                addWebViewByURLString(requestTokenAPI)
            }
        }
    }
}


// MARK: WKNavigationDelegate

extension MonkeyKing: WKNavigationDelegate {

    public func webView(webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: NSError) {

        // Pocket OAuth
        if let errorString = error.userInfo["NSErrorFailingURLStringKey"] as? String where errorString.hasSuffix(":authorizationFinished") {
            hideWebView(webView, tuples: (nil, nil, nil))
        }
    }

    public func webView(webView: WKWebView, didFinishNavigation navigation: WKNavigation!) {

        activityIndicatorViewAction(webView, stop: true)

        guard let URL = webView.URL else {
            return
        }

        let absoluteString = URL.absoluteString

        var scriptString = "var button = document.createElement('a'); button.setAttribute('href', 'about:blank'); button.innerHTML = '关闭'; button.setAttribute('style', 'width: calc(100% - 40px); background-color: gray;display: inline-block;height: 40px;line-height: 40px;text-align: center;color: #777777;text-decoration: none;border-radius: 3px;background: linear-gradient(180deg, white, #f1f1f1);border: 1px solid #CACACA;box-shadow: 0 2px 3px #DEDEDE, inset 0 0 0 1px white;text-shadow: 0 2px 0 white;position: fixed;left: 0;bottom: 0;margin: 20px;font-size: 18px;'); document.body.appendChild(button);"

        if absoluteString.containsString("getpocket.com") {
            scriptString += "document.querySelector('div.toolbar').style.display = 'none';"
            scriptString += "document.querySelector('a.extra_action').style.display = 'none';"
            scriptString += "var rightButton = $('.toolbarContents div:last-child');"
            scriptString += "if (rightButton.html() == 'Log In') {rightButton.click()}"
        } else if absoluteString.containsString("open.weibo.cn") {
            scriptString += "document.querySelector('aside.logins').style.display = 'none';"
        }

        webView.evaluateJavaScript(scriptString, completionHandler: nil)
    }

    public func webView(webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {

        guard let URL = webView.URL else {
            webView.stopLoading()
            return
        }

        // Close Button
        if URL.absoluteString.containsString("about:blank") {
            let error = NSError(domain: "User Cancelled", code: -1, userInfo: nil)
            hideWebView(webView, tuples: (nil, nil, error))
        }

        // QQ Web OAuth
        guard URL.absoluteString.containsString("&access_token=") && URL.absoluteString.containsString("qzs.qq.com") else {
            return
        }

        guard let fragment = URL.fragment?.characters.dropFirst(), newURL = NSURL(string: "http://qzs.qq.com/?\(String(fragment))") else {
            return
        }

        let queryItems = newURL.monkeyking_queryItems
        hideWebView(webView, tuples: (queryItems, nil, nil))
    }

    public func webView(webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {

        guard let URL = webView.URL else {
            return
        }

        // Weibo OAuth
        for case let .Weibo(appID, appKey, redirectURL) in accountSet {
            if URL.absoluteString.lowercaseString.hasPrefix(redirectURL) {

                webView.stopLoading()

                guard let code = URL.monkeyking_queryItems["code"] as? String else {
                    return
                }

                var accessTokenAPI = "https://api.weibo.com/oauth2/access_token?"
                accessTokenAPI += "client_id=" + appID
                accessTokenAPI += "&client_secret=" + appKey
                accessTokenAPI += "&grant_type=authorization_code&"
                accessTokenAPI += "redirect_uri=" + redirectURL
                accessTokenAPI += "&code=" + code

                activityIndicatorViewAction(webView, stop: false)

                request(accessTokenAPI, method: .POST) { [weak self] (JSON, response, error) -> Void in
                    dispatch_async(dispatch_get_main_queue()) {
                        self?.hideWebView(webView, tuples: (JSON, response, error))
                    }
                }
            }
        }
    }
}


// MARK: Private Methods

extension MonkeyKing {

    private class func fetchWeChatOAuthInfoByCode(code code: String, completionHandler: MKGNetworkingResponseHandler) {

        var appID = ""
        var appKey = ""
        for case let .WeChat(id, key) in sharedMonkeyKing.accountSet {

            guard let key = key else {
                completionHandler(["code": code], nil, nil)
                return
            }

            appID = id
            appKey = key
        }

        var accessTokenAPI = "https://api.weixin.qq.com/sns/oauth2/access_token?"
        accessTokenAPI += "appid=" + appID
        accessTokenAPI += "&secret=" + appKey
        accessTokenAPI += "&code=" + code + "&grant_type=authorization_code"

        // OAuth
        sharedMonkeyKing.request(accessTokenAPI, method: .GET) { (OAuthJSON, response, error) -> Void in
            completionHandler(OAuthJSON, response, error)
        }
    }

    private func request(URLString: String, method: MKGMethod, parameters: [String: AnyObject]? = nil, encoding: MKGParameterEncoding = .URL, headers: [String: String]? = nil, completionHandler: MKGNetworkingResponseHandler) {

        guard let networkingDelegate = MonkeyKing.sharedMonkeyKing as? protocol<MKGNetworkingProtocol> else {
            MKGNetworking.sharedInstance.request(URLString, method: method, parameters: parameters, encoding: encoding, headers: headers, completionHandler: completionHandler)
            return
        }

        networkingDelegate.request(URLString, method: method, parameters: parameters, encoding: encoding, headers: headers, completionHandler: completionHandler)
    }

    private func upload(URLString: String, parameters: [String: AnyObject], completionHandler: MKGNetworkingResponseHandler) {

        guard let networkingDelegate = MonkeyKing.sharedMonkeyKing as? protocol<MKGNetworkingProtocol> else {
            MKGNetworking.sharedInstance.upload(URLString, parameters: parameters, completionHandler: completionHandler)
            return
        }

        networkingDelegate.upload(URLString, parameters: parameters, completionHandler: completionHandler)
    }

    private class func addWebViewByURLString(URLString: String) {

        guard let URL = NSURL(string: URLString) else {
            return
        }

        let webView = WKWebView()
        webView.frame = UIScreen.mainScreen().bounds
        webView.frame.origin.y = UIScreen.mainScreen().bounds.height

        webView.loadRequest(NSURLRequest(URL: URL))
        webView.navigationDelegate = sharedMonkeyKing
        webView.backgroundColor = UIColor(red: 247/255, green: 247/255, blue: 247/255, alpha: 1.0)
        webView.scrollView.frame.origin.y = 20
        webView.scrollView.backgroundColor = webView.backgroundColor

        let activityIndicatorView = UIActivityIndicatorView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        activityIndicatorView.center = CGPoint(x: CGRectGetMidX(webView.bounds), y: CGRectGetMidY(webView.bounds)+30)
        activityIndicatorView.activityIndicatorViewStyle = .Gray

        webView.scrollView.addSubview(activityIndicatorView)
        activityIndicatorView.startAnimating()

        UIApplication.sharedApplication().keyWindow?.addSubview(webView)
        UIView.animateWithDuration(0.32, delay: 0.0, options: .CurveEaseOut, animations: {
            webView.frame.origin.y = 0
        }, completion: nil)
    }

    private func hideWebView(webView: WKWebView, tuples: (NSDictionary?, NSURLResponse?, NSError?)?) {

        activityIndicatorViewAction(webView, stop: true)
        webView.stopLoading()

        UIView.animateWithDuration(0.3, delay: 0.0, options: .CurveEaseOut, animations: {
            webView.frame.origin.y = UIScreen.mainScreen().bounds.height

        }, completion: {_ in
            webView.removeFromSuperview()
            self.OAuthCompletionHandler?(tuples?.0, tuples?.1, tuples?.2)
        })
    }

    private func activityIndicatorViewAction(webView: WKWebView, stop: Bool) {
        for subview in webView.scrollView.subviews {
            if let activityIndicatorView = subview as? UIActivityIndicatorView {
                guard stop else {
                    activityIndicatorView.startAnimating()
                    return
                }
                activityIndicatorView.stopAnimating()
            }
        }
    }

    private class func openURL(URLString URLString: String) -> Bool {

        guard let URL = NSURL(string: URLString) else {
            return false
        }

        return UIApplication.sharedApplication().openURL(URL)
    }

    private func canOpenURL(URLString URLString: String) -> Bool {

        guard let URL = NSURL(string: URLString) else {
            return false
        }

        return UIApplication.sharedApplication().canOpenURL(URL)
    }
}


// MARK: Private Extensions

private extension Set {

    subscript(platform: MonkeyKing.OAuthPlatform) -> MonkeyKing.Account? {

        let accountSet = MonkeyKing.sharedMonkeyKing.accountSet

        switch platform {

        case .WeChat:
            for account in accountSet {
                if case .WeChat = account {
                    return account
                }
            }
        case .QQ:
            for account in accountSet {
                if case .QQ = account {
                    return account
                }
            }
        case .Weibo:
            for account in accountSet {
                if case .Weibo = account {
                    return account
                }
            }
        case .Pocket:
            for account in accountSet {
                if case .Pocket = account {
                    return account
                }
            }
        }
        
        return nil
    }

    subscript(platform: MonkeyKing.Message) -> MonkeyKing.Account? {

        let accountSet = MonkeyKing.sharedMonkeyKing.accountSet

        switch platform {

        case .WeChat:
            for account in accountSet {
                if case .WeChat = account {
                    return account
                }
            }
        case .QQ:
            for account in accountSet {
                if case .QQ = account {
                    return account
                }
            }
        case .Weibo:
            for account in accountSet {
                if case .Weibo = account {
                    return account
                }
            }
        }

        return nil
    }
}

private extension NSBundle {

    var monkeyking_displayName: String? {

        func getNameByInfo(info: [String : AnyObject]) -> String? {

            guard let displayName = info["CFBundleDisplayName"] as? String else {
                return info["CFBundleName"] as? String
            }

            return displayName
        }

        guard let info = localizedInfoDictionary ?? infoDictionary else {
            return nil
        }

        return getNameByInfo(info)
    }

    var monkeyking_bundleID: String? {
        return objectForInfoDictionaryKey("CFBundleIdentifier") as? String
    }
}

private extension String {

    var monkeyking_base64EncodedString: String? {
        return dataUsingEncoding(NSUTF8StringEncoding)?.base64EncodedStringWithOptions(NSDataBase64EncodingOptions(rawValue: 0))
    }

    var monkeyking_urlEncodedString: String? {
        return stringByAddingPercentEncodingWithAllowedCharacters(NSCharacterSet.URLHostAllowedCharacterSet())
    }

    var monkeyking_base64AndURLEncodedString: String? {
        return monkeyking_base64EncodedString?.monkeyking_urlEncodedString
    }

    var monkeyking_QQCallbackName: String {

        var hexString = String(format: "%02llx", (self as NSString).longLongValue)
        while hexString.characters.count < 8 {
            hexString = "0" + hexString
        }

        return "QQ" + hexString
    }
}

private extension NSURL {

    var monkeyking_queryItems: [String: AnyObject] {

        var infos = [String: AnyObject]()

        let components = NSURLComponents(URL: self, resolvingAgainstBaseURL: false)

        guard let items = components?.queryItems else {
            return infos
        }

        items.forEach {
            infos[$0.name] = $0.value
        }
        return infos
    }
}

private extension UIImage {

    var monkeyking_compressedImageData: NSData? {

        var compressionQuality: CGFloat = 0.5

        func compresseImage(image: UIImage) -> NSData? {

            let maxHeight: CGFloat = 240.0
            let maxWidth: CGFloat = 240.0
            var actualHeight: CGFloat = image.size.height
            var actualWidth: CGFloat = image.size.width
            var imgRatio: CGFloat = actualWidth/actualHeight
            let maxRatio: CGFloat = maxWidth/maxHeight

            if actualHeight > maxHeight || actualWidth > maxWidth {

                if imgRatio < maxRatio { // adjust width according to maxHeight

                    imgRatio = maxHeight / actualHeight
                    actualWidth = imgRatio * actualWidth
                    actualHeight = maxHeight

                } else if imgRatio > maxRatio { // adjust height according to maxWidth

                    imgRatio = maxWidth / actualWidth
                    actualHeight = imgRatio * actualHeight
                    actualWidth = maxWidth

                } else {
                    actualHeight = maxHeight
                    actualWidth = maxWidth
                }
            }

            let rect = CGRectMake(0.0, 0.0, actualWidth, actualHeight)
            UIGraphicsBeginImageContext(rect.size)
            image.drawInRect(rect)
            let imageData = UIImageJPEGRepresentation(UIGraphicsGetImageFromCurrentImageContext(), compressionQuality)
            UIGraphicsEndImageContext()

            return imageData
        }

        var imageData = compresseImage(self)

        guard imageData != nil else {
            return nil
        }

        let minCompressionQuality: CGFloat = 0.001
        while imageData!.length > 31000 && compressionQuality != minCompressionQuality {
            compressionQuality = max(compressionQuality - 0.1, minCompressionQuality)
            guard let image = UIImage(data: imageData!) else {
                compressionQuality = minCompressionQuality
                break
            }
            imageData = compresseImage(image)
        }
        
        return imageData
    }
}

