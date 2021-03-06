//
//  Manager.swift
//  Potatso
//
//  Created by LEI on 4/7/16.
//  Copyright © 2016 TouchingApp. All rights reserved.
//

import PotatsoBase
import PotatsoModel
import RealmSwift
import KissXML
import NetworkExtension
import ICSMainFramework
import MMWormhole

public enum ManagerError: ErrorType {
    case InvalidProvider
    case VPNStartFail
}

public enum VPNStatus {
    case Off
    case Connecting
    case On
    case Disconnecting
}


public let kDefaultGroupIdentifier = "defaultGroup"
public let kDefaultGroupName = "defaultGroupName"
private let statusIdentifier = "status"
public let kProxyServiceVPNStatusNotification = "kProxyServiceVPNStatusNotification"

public class Manager {
    
    public static let sharedManager = Manager()
    
    public private(set) var vpnStatus = VPNStatus.Off {
        didSet {
            NSNotificationCenter.defaultCenter().postNotificationName(kProxyServiceVPNStatusNotification, object: nil)
        }
    }
    
    public let wormhole = MMWormhole(applicationGroupIdentifier: sharedGroupIdentifier, optionalDirectory: "wormhole")

    var observerAdded: Bool = false
    
    public private(set) var defaultConfigGroup: ConfigurationGroup!

    private init() {
        loadProviderManager { (manager) -> Void in
            if let manager = manager {
                self.updateVPNStatus(manager)
            }
        }
        addVPNStatusObserver()
    }
    
    func addVPNStatusObserver() {
        guard !observerAdded else{
            return
        }
        loadProviderManager { [unowned self] (manager) -> Void in
            if let manager = manager {
                self.observerAdded = true
                NSNotificationCenter.defaultCenter().addObserverForName(NEVPNStatusDidChangeNotification, object: manager.connection, queue: NSOperationQueue.mainQueue(), usingBlock: { [unowned self] (notification) -> Void in
                    self.updateVPNStatus(manager)
                })
            }
        }
    }
    
    deinit {
        NSNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    func updateVPNStatus(manager: NEVPNManager) {
        switch manager.connection.status {
        case .Connected:
            self.vpnStatus = .On
        case .Connecting, .Reasserting:
            self.vpnStatus = .Connecting
        case .Disconnecting:
            self.vpnStatus = .Disconnecting
        case .Disconnected, .Invalid:
            self.vpnStatus = .Off
        }
    }

    public func switchVPN(completion: ((NETunnelProviderManager?, ErrorType?) -> Void)? = nil) {
        loadProviderManager { [unowned self] (manager) in
            if let manager = manager {
                self.updateVPNStatus(manager)
            }
            let current = self.vpnStatus
            guard current != .Connecting && current != .Disconnecting else {
                return
            }
            if current == .Off {
                self.startVPN { (manager, error) -> Void in
                    completion?(manager, error)
                }
            }else {
                self.stopVPN()
                completion?(nil, nil)
            }

        }
    }
    
    public func switchVPNFromTodayWidget(context: NSExtensionContext) {
        if let url = NSURL(string: "potatso://switch") {
            context.openURL(url, completionHandler: nil)
        }
    }
    
    public func setup() throws {
        setupDefaultReaml()
        try initDefaultConfigGroup()
        do {
            try copyGEOIPData()
            try copyTemplateData()
        }catch{
            print("copy fail")
        }
    }
    
    func copyGEOIPData() throws {
        for country in ["CN"] {
            guard let fromURL = NSBundle.mainBundle().URLForResource("geoip-\(country)", withExtension: "data") else {
                return
            }
            let toURL = Potatso.sharedUrl().URLByAppendingPathComponent("httpconf/geoip-\(country).data")
            if NSFileManager.defaultManager().fileExistsAtPath(fromURL.path!) {
                if NSFileManager.defaultManager().fileExistsAtPath(toURL.path!) {
                    try NSFileManager.defaultManager().removeItemAtURL(toURL)
                }
                try NSFileManager.defaultManager().copyItemAtURL(fromURL, toURL: toURL)
            }
        }
    }

    func copyTemplateData() throws {
        guard let bundleURL = NSBundle.mainBundle().URLForResource("template", withExtension: "bundle") else {
            return
        }
        let fm = NSFileManager.defaultManager()
        let toDirectoryURL = Potatso.sharedUrl().URLByAppendingPathComponent("httptemplate")
        if !fm.fileExistsAtPath(toDirectoryURL.path!) {
            try fm.createDirectoryAtURL(toDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        }
        for file in try fm.contentsOfDirectoryAtPath(bundleURL.path!) {
            let destURL = toDirectoryURL.URLByAppendingPathComponent(file)
            let dataURL = bundleURL.URLByAppendingPathComponent(file)
            if NSFileManager.defaultManager().fileExistsAtPath(dataURL.path!) {
                if NSFileManager.defaultManager().fileExistsAtPath(destURL.path!) {
                    try NSFileManager.defaultManager().removeItemAtURL(destURL)
                }
                try fm.copyItemAtURL(dataURL, toURL: destURL)
            }
        }
    }

    public func initDefaultConfigGroup() throws {
        if let groupUUID = Potatso.sharedUserDefaults().stringForKey(kDefaultGroupIdentifier), group = defaultRealm.objects(ConfigurationGroup).filter("uuid = '\(groupUUID)'").first{
            try setDefaultConfigGroup(group)
        }else {
            var group: ConfigurationGroup
            if let g = defaultRealm.objects(ConfigurationGroup).first {
                group = g
            }else {
                group = ConfigurationGroup()
                group.name = "Default".localized()
                do {
                    try defaultRealm.write {
                        defaultRealm.add(group)
                    }
                }catch {
                    fatalError("Fail to generate default group")
                }
            }
            try setDefaultConfigGroup(group)
        }
    }
    
    public func setDefaultConfigGroup(group: ConfigurationGroup) throws {
        defaultConfigGroup = group
        try regenerateConfigFiles()
        let uuid = defaultConfigGroup.uuid
        let name = defaultConfigGroup.name
        Potatso.sharedUserDefaults().setObject(uuid, forKey: kDefaultGroupIdentifier)
        Potatso.sharedUserDefaults().setObject(name, forKey: kDefaultGroupName)
        Potatso.sharedUserDefaults().synchronize()
    }
    
    public func regenerateConfigFiles() throws {
        try generateGeneralConfig()
        try generateSocksConfig()
        try generateShadowsocksConfig()
        try generateHttpProxyConfig()
    }

}

extension ConfigurationGroup {

    public var isDefault: Bool {
        let defaultUUID = Manager.sharedManager.defaultConfigGroup.uuid
        let isDefault = defaultUUID == uuid
        return isDefault
    }
    
}

extension Manager {
    
    var upstreamProxy: Proxy? {
        return defaultConfigGroup.proxies.first
    }
    
    var defaultToProxy: Bool {
        return defaultConfigGroup.defaultToProxy ?? false
    }
    
    func generateGeneralConfig() throws {
        let confURL = Potatso.sharedGeneralConfUrl()
        let json: NSDictionary = ["dns": defaultConfigGroup.dns ?? ""]
        try json.jsonString()?.writeToURL(confURL, atomically: true, encoding: NSUTF8StringEncoding)
    }
    
    func generateSocksConfig() throws {
        let root = NSXMLElement.elementWithName("antinatconfig") as! NSXMLElement
        let interface = NSXMLElement.elementWithName("interface", children: nil, attributes: [NSXMLNode.attributeWithName("value", stringValue: "127.0.0.1")]) as! NSXMLElement
        root.addChild(interface)
        
        let port = NSXMLElement.elementWithName("port", children: nil, attributes: [NSXMLNode.attributeWithName("value", stringValue: "0")])  as! NSXMLElement
        root.addChild(port)
        
        let maxbindwait = NSXMLElement.elementWithName("maxbindwait", children: nil, attributes: [NSXMLNode.attributeWithName("value", stringValue: "10")]) as! NSXMLElement
        root.addChild(maxbindwait)
        
        
        let authchoice = NSXMLElement.elementWithName("authchoice") as! NSXMLElement
        let select = NSXMLElement.elementWithName("select", children: nil, attributes: [NSXMLNode.attributeWithName("mechanism", stringValue: "anonymous")])  as! NSXMLElement
        
        authchoice.addChild(select)
        root.addChild(authchoice)
        
        let filter = NSXMLElement.elementWithName("filter") as! NSXMLElement
        if let upstreamProxy = upstreamProxy {
            let chain = NSXMLElement.elementWithName("chain", children: nil, attributes: [NSXMLNode.attributeWithName("name", stringValue: upstreamProxy.name)]) as! NSXMLElement
            switch upstreamProxy.type {
            case .Shadowsocks:
                let uriString = "socks5://127.0.0.1:${ssport}"
                let uri = NSXMLElement.elementWithName("uri", children: nil, attributes: [NSXMLNode.attributeWithName("value", stringValue: uriString)]) as! NSXMLElement
                chain.addChild(uri)
                let authscheme = NSXMLElement.elementWithName("authscheme", children: nil, attributes: [NSXMLNode.attributeWithName("value", stringValue: "anonymous")]) as! NSXMLElement
                chain.addChild(authscheme)
            default:
                break
            }
            root.addChild(chain)
        }
        
        let accept = NSXMLElement.elementWithName("accept") as! NSXMLElement
        filter.addChild(accept)
        root.addChild(filter)
        
        let socksConf = root.XMLString()
        try socksConf.writeToURL(Potatso.sharedSocksConfUrl(), atomically: true, encoding: NSUTF8StringEncoding)
    }
    
    func generateShadowsocksConfig() throws {
        guard let upstreamProxy = upstreamProxy where upstreamProxy.type == .Shadowsocks else {
            return
        }
        let confURL = Potatso.sharedProxyConfUrl()
        let json = ["host": upstreamProxy.host, "port": upstreamProxy.port, "password": upstreamProxy.password ?? "", "authscheme": upstreamProxy.authscheme ?? "", "ota": upstreamProxy.ota]
        try json.jsonString()?.writeToURL(confURL, atomically: true, encoding: NSUTF8StringEncoding)
    }
    
    func generateHttpProxyConfig() throws {
        let rootUrl = Potatso.sharedUrl()
        let confDirUrl = rootUrl.URLByAppendingPathComponent("httpconf")
        let templateDirPath = rootUrl.URLByAppendingPathComponent("httptemplate").path!
        let temporaryDirPath = rootUrl.URLByAppendingPathComponent("httptemporary").path!
        let logDir = rootUrl.URLByAppendingPathComponent("log").path!
        for p in [confDirUrl.path!, templateDirPath, temporaryDirPath, logDir] {
            if !NSFileManager.defaultManager().fileExistsAtPath(p) {
                _ = try? NSFileManager.defaultManager().createDirectoryAtPath(p, withIntermediateDirectories: true, attributes: nil)
            }
        }
        let directString = "forward ."
        var proxyString = directString
        var defaultRouteString = "default-route"
        var defaultProxyString = "."

        if let upstreamProxy = upstreamProxy {
            switch upstreamProxy.type {
            case .Shadowsocks:
                proxyString = "forward-socks5 127.0.0.1:${ssport} ."
                if defaultToProxy {
                    defaultRouteString = "default-route-socks5"
                    defaultProxyString = "127.0.0.1:${ssport} ."
                }
            default:
                break
            }
        }
        let mainConf: [(String, AnyObject)] = [("confdir", confDirUrl.path!),
                                             ("templdir", templateDirPath),
                                             ("logdir", logDir),
                                             ("listen-address", "127.0.0.1:0"),
                                             ("toggle", 1),
                                             ("enable-remote-toggle", 0),
                                             ("enable-remote-http-toggle", 0),
                                             ("enable-edit-actions", 0),
                                             ("enforce-blocks", 0),
                                             ("buffer-limit", 512),
                                             ("enable-proxy-authentication-forwarding", 0),
                                             ("accept-intercepted-requests", 0),
                                             ("allow-cgi-request-crunching", 0),
                                             ("split-large-forms", 0),
                                             ("keep-alive-timeout", 5),
                                             ("tolerate-pipelining", 1),
                                             ("socket-timeout", 300),
//                                             ("debug", 1024+65536+1),
                                             ("debug", 8192),
                                             ("actionsfile", "user.action"),
                                             (defaultRouteString, defaultProxyString),
//                                             ("debug", 131071)
                                             ]
        var actionContent: [String] = []
        var forwardIPDirectContent: [String] = []
        var forwardIPProxyContent: [String] = []
        var forwardURLDirectContent: [String] = []
        var forwardURLProxyContent: [String] = []
        var blockContent: [String] = []
        let rules = defaultConfigGroup.ruleSets.map({ $0.rules }).flatMap({ $0 })
        for rule in rules {
            if rule.type == .GeoIP {
                switch rule.action {
                case .Direct:
                    if (!forwardIPDirectContent.contains(rule.value)) {
                        forwardIPDirectContent.append(rule.value)
                    }
                case .Proxy:
                    if (!forwardIPProxyContent.contains(rule.value)) {
                        forwardIPProxyContent.append(rule.value)
                    }
                case .Reject:
                    break
                }
            }else if (rule.type == .IPCIDR) {
                switch rule.action {
                case .Direct:
                    forwardIPDirectContent.append(rule.value)
                case .Proxy:
                    forwardIPProxyContent.append(rule.value)
                case .Reject:
                    break
                }
            }else {
                switch rule.action {
                case .Direct:
                    forwardURLDirectContent.append(rule.pattern)
                    break
                case .Proxy:
                    forwardURLProxyContent.append(rule.pattern)
                    break
                case .Reject:
                    blockContent.append(rule.pattern)
                }
            }
        }

        let mainContent = mainConf.map { "\($0) \($1)"}.joinWithSeparator("\n")
        try mainContent.writeToURL(Potatso.sharedHttpProxyConfUrl(), atomically: true, encoding: NSUTF8StringEncoding)

        if let _ = upstreamProxy {
            if forwardURLProxyContent.count > 0 {
                actionContent.append("{+forward-override{\(proxyString)}}")
                actionContent.appendContentsOf(forwardURLProxyContent)
            }
            if forwardIPProxyContent.count > 0 {
                actionContent.append("{+forward-resolved-ip{\(proxyString)}}")
                actionContent.appendContentsOf(forwardIPProxyContent)
                actionContent.appendContentsOf(Pollution.dnsList.map({ $0 + "/32" }))
            }
        }

        if forwardURLDirectContent.count > 0 {
            actionContent.append("{+forward-override{\(directString)}}")
            actionContent.appendContentsOf(forwardURLDirectContent)
        }

        if forwardIPDirectContent.count > 0 {
            actionContent.append("{+forward-resolved-ip{\(directString)}}")
            actionContent.appendContentsOf(forwardIPDirectContent)
        }

        if blockContent.count > 0 {
            actionContent.append("{+block{Blocked} +handle-as-empty-document}")
            actionContent.appendContentsOf(blockContent)
        }


        let userActionString = actionContent.joinWithSeparator("\n")
        let userActionUrl = confDirUrl.URLByAppendingPathComponent("user.action")
        try userActionString.writeToFile(userActionUrl.path!, atomically: true, encoding: NSUTF8StringEncoding)
    }

}

extension Manager {
    
    public func isVPNStarted(complete: (Bool, NETunnelProviderManager?) -> Void) {
        loadProviderManager { (manager) -> Void in
            if let manager = manager {
                complete(manager.connection.status == .Connected, manager)
            }else{
                complete(false, nil)
            }
        }
    }
    
    public func startVPN(complete: ((NETunnelProviderManager?, ErrorType?) -> Void)? = nil) {
        startVPNWithOptions(nil, complete: complete)
    }
    
    private func startVPNWithOptions(options: [String : NSObject]?, complete: ((NETunnelProviderManager?, ErrorType?) -> Void)? = nil) {
        // regenerate config files
        do {
            try Manager.sharedManager.regenerateConfigFiles()
        }catch {
            complete?(nil, error)
            return
        }
        // Load provider
        loadAndCreateProviderManager { (manager, error) -> Void in
            if let error = error {
                complete?(nil, error)
            }else{
                guard let manager = manager else {
                    complete?(nil, ManagerError.InvalidProvider)
                    return
                }
                if manager.connection.status == .Disconnected || manager.connection.status == .Invalid {
                    do {
                        try manager.connection.startVPNTunnelWithOptions(options)
                        self.addVPNStatusObserver()
                        complete?(manager, nil)
                    }catch {
                        complete?(nil, error)
                    }
                }else{
                    self.addVPNStatusObserver()
                    complete?(manager, nil)
                }
            }
        }
    }
    
    public func stopVPN() {
        // Stop provider
        loadProviderManager { (manager) -> Void in
            guard let manager = manager else {
                return
            }
            manager.connection.stopVPNTunnel()
        }
    }
    
    public func postMessage() {
        loadProviderManager { (manager) -> Void in
            if let session = manager?.connection as? NETunnelProviderSession,
                message = "Hello".dataUsingEncoding(NSUTF8StringEncoding)
                where manager?.connection.status != .Invalid
            {
                do {
                    try session.sendProviderMessage(message) { response in
                        
                    }
                } catch {
                    print("Failed to send a message to the provider")
                }
            }
        }
    }
    
    private func loadAndCreateProviderManager(complete: (NETunnelProviderManager?, ErrorType?) -> Void ) {
        NETunnelProviderManager.loadAllFromPreferencesWithCompletionHandler { [unowned self] (managers, error) -> Void in
            if let managers = managers {
                let manager: NETunnelProviderManager
                if managers.count > 0 {
                    manager = managers[0]
                }else{
                    manager = self.createProviderManager()
                }
                manager.enabled = true
                manager.localizedDescription = AppEnv.appName
                manager.protocolConfiguration?.serverAddress = AppEnv.appName
                manager.onDemandEnabled = true
                let quickStartRule = NEOnDemandRuleEvaluateConnection()
                quickStartRule.connectionRules = [NEEvaluateConnectionRule(matchDomains: ["potatso.com"], andAction: NEEvaluateConnectionRuleAction.ConnectIfNeeded)]
                manager.onDemandRules = [quickStartRule]
                manager.saveToPreferencesWithCompletionHandler({ (error) -> Void in
                    if let error = error {
                        complete(nil, error)
                    }else{
                        manager.loadFromPreferencesWithCompletionHandler({ (error) -> Void in
                            if let error = error {
                                complete(nil, error)
                            }else{
                                complete(manager, nil)
                            }
                        })
                    }
                })
            }else{
                complete(nil, error)
            }
        }
    }
    
    public func loadProviderManager(complete: (NETunnelProviderManager?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferencesWithCompletionHandler { (managers, error) -> Void in
            if let managers = managers {
                if managers.count > 0 {
                    let manager = managers[0]
                    complete(manager)
                    return
                }
            }
            complete(nil)
        }
    }
    
    private func createProviderManager() -> NETunnelProviderManager {
        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = NETunnelProviderProtocol()
        return manager
    }
}
