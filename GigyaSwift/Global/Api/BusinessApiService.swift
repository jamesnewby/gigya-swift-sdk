//
//  ApiManager.swift
//  GigyaSwift
//
//  Created by Shmuel, Sagi on 05/03/2019.
//  Copyright © 2019 Gigya. All rights reserved.
//

import UIKit

class BusinessApiService: NSObject, BusinessApiServiceProtocol {

    let config: GigyaConfig

    let persistenceService: PersistenceService

    let apiService: ApiServiceProtocol

    var sessionService: SessionServiceProtocol

    var biometricService: BiometricServiceInternalProtocol

    var accountService: AccountServiceProtocol

    var socialProviderFactory: SocialProvidersManagerProtocol

    var providerAdapter: Provider?

    var interruptionsHandler: InterruptionResolverFactoryProtocol

    var providersFactory: ProvidersLoginWrapper?
    
    var saptchaService: SaptchaService?

    required init(config: GigyaConfig,
                  persistenceService: PersistenceService,
                  apiService: ApiServiceProtocol,
                  sessionService: SessionServiceProtocol,
                  accountService: AccountServiceProtocol,
                  providerFactory: SocialProvidersManagerProtocol,
                  interruptionsHandler: InterruptionResolverFactoryProtocol,
                  biometricService: BiometricServiceInternalProtocol) {
        self.config = config
        self.persistenceService = persistenceService
        self.apiService = apiService
        self.sessionService = sessionService
        self.biometricService = biometricService
        self.accountService = accountService
        self.socialProviderFactory = providerFactory
        self.interruptionsHandler = interruptionsHandler

    }

    // Send regular request
    func send(api: String, params: [String: Any] = [:], completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void ) {
        let model = ApiRequestModel(method: api, params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self, completion: completion)
    }

    // Send request with generic type.
    func send<T: Codable>(dataType: T.Type, api: String, params: [String: Any] = [:], completion: @escaping (GigyaApiResult<T>) -> Void ) {
        let model = ApiRequestModel(method: api, params: params)

        apiService.send(model: model, responseType: T.self, completion: completion)
    }

    func getAccount<T: Codable>(params: [String: Any] = [:], clearAccount: Bool = false, dataType: T.Type, completion: @escaping (GigyaApiResult<T>) -> Void) {
        if clearAccount == true {
            accountService.clear()
        }

        if accountService.isCachedAccount() {
            completion(.success(data: accountService.getAccount()))
        } else {

            let model = ApiRequestModel(method: GigyaDefinitions.API.getAccountInfo, params: params, config: config)
            
            apiService.send(model: model, responseType: T.self) { [weak accountService] result in
                switch result {
                case .success(let data):
                    accountService?.account = data
                    completion(result)
                case .failure:
                    completion(result)
                }
            }
        }
    }

    func setAccount<T: Codable>(obj: T, completion: @escaping (GigyaApiResult<T>) -> Void) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let diffParams = self?.accountService.setAccount(newAccount: obj)
            let model = ApiRequestModel(method: GigyaDefinitions.API.setAccountInfo, params: diffParams)

            self?.apiService.send(model: model, responseType: GigyaDictionary.self) { [weak self] result in
                switch result {
                case .success:
                    self?.accountService.clear()
                    self?.getAccount(dataType: T.self, completion: completion)
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func setAccount<T: Codable>(params: [String: Any], completion: @escaping (GigyaApiResult<T>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.setAccountInfo, params: params)

        apiService.send(model: model, responseType: T.self) { [weak self] result in
            switch result {
            case .success:
                self?.accountService.clear()
                self?.getAccount(dataType: T.self, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func register<T: GigyaAccountProtocol>(email: String, password: String, params: [String: Any], dataType: T.Type, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.initRegistration, config: config)

        apiService.send(model: model, responseType: [String: AnyCodable].self) { [weak self] (result) in
            switch result {
            case .success(let data):
                let regToken = data["regToken"]?.value ?? ""
                let makeParams: [String: Any] = ["email": email, "password": password, "regToken": regToken, "finalizeRegistration": "true"].merging(params) { $1 }

                let model = ApiRequestModel(method: GigyaDefinitions.API.register, params: makeParams, config: self?.config)

                self?.apiService.send(model: model, responseType: T.self) { result in
                    switch result {
                    case .success(let data):
                        completion(.success(data: data))

                        self?.clearOptionalObjects()
                    case .failure(let error):
                        self?.interruptionResolver(error: error, completion: completion, model: model)
                    }
                }

            case .failure(let error):
                let loginError = LoginApiError<T>(error: error, interruption: nil)
                completion(.failure(loginError))
            }
        }
    }

    func login<T: GigyaAccountProtocol>(dataType: T.Type, loginId: String, password: String, params: [String: Any], completion: @escaping (GigyaLoginResult<T>) -> Void) {
        var loginParams = params
        loginParams["loginID"] = loginId
        loginParams["password"] = password

        login(params: loginParams, completion: completion)
    }

    func login<T: GigyaAccountProtocol>(dataType: T.Type, params: [String: Any], completion: @escaping (GigyaLoginResult<T>) -> Void) {
        login(params: params, completion: completion)
    }

    func login<T: GigyaAccountProtocol>(params: [String: Any], completion: @escaping (GigyaLoginResult<T>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.login, params: params, config: config)

        apiService.send(model: model, responseType: T.self) { [weak self] result in
            switch result {
            case .success(let data):
                self?.accountService.account = data

                completion(.success(data: data))
                
                self?.clearOptionalObjects()
            case .failure(let error):
                self?.interruptionResolver(error: error, completion: completion, model: model)
            }
        }
    }

    func login<T: GigyaAccountProtocol>(provider: GigyaSocialProviders, viewController: UIViewController,
                           params: [String: Any], dataType: T.Type, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        providerAdapter = socialProviderFactory.getProvider(with: provider, delegate: self)

        var loginMode = "standard"
        if let mode = params["loginMode"] as? String {
            loginMode = mode
        }
        var newParams = params
        newParams["conflictHandling"] = "fail"

        providerAdapter?.login(type: T.self, params: newParams, viewController: viewController, loginMode: loginMode) { (result) in
            switch result {
            case .success(let data):
                completion(.success(data: data))
            case .failure(let error):
                self.interruptionResolver(error: error, completion: completion)
            }
        }

        providerAdapter?.didFinish = { [weak self] in
            self?.clearOptionalObjects()
        }
    }

    func login<T: GigyaAccountProtocol>(providers: [GigyaSocialProviders], viewController: UIViewController, params: [String: Any], completion: @escaping (GigyaLoginResult<T>) -> Void) {
        providersFactory = ProvidersLoginWrapper(config: config, persistenceService: persistenceService, providers: providers)
        providersFactory?.show(params: params, viewController: viewController) { [weak self] json, error in
            if error == GigyaDefinitions.Plugin.canceled {
                let error = LoginApiError<T>(error: .providerError(data: error ?? ""), interruption: nil)

                completion(.failure(error))
                return
            }

            if let providerString = json?["provider"] as? String,
               let provider = GigyaSocialProviders(rawValue: providerString),
               let vc = self?.providersFactory?.webViewController
                {
                self?.login(provider: provider, viewController: vc, params: params, dataType: T.self) { [weak self] result in
                    switch result {
                    case .success:
                        self?.dismissProvidersLogin()
                    case .failure(let errorObject):
                        guard case .providerError = errorObject.error else {
                            self?.dismissProvidersLogin()
                            completion(result)
                            return
                        }
                    }
                    completion(result)
                }
            }
        }
    }

    func verifyLogin<T: GigyaAccountProtocol>(UID: String, params: [String: Any], completion: @escaping (GigyaApiResult<T>) -> Void) {
        var params: [String: Any] = params
        params["loginID"] = UID

        let model = ApiRequestModel(method: GigyaDefinitions.API.verifyLogin, params: params, config: config)

        apiService.send(model: model, responseType: T.self) { result in
            switch result {
            case .success(let result):
                completion(.success(data: result))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func notifySocialLogin<T: Codable>(params: [String: Any], completion: @escaping (GigyaApiResult<T>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.notifySocialLogin, params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self) { [weak self] result in
            switch result {
            case .success:
                self?.getAccount(clearAccount: true, dataType: T.self, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func addConnection<T: GigyaAccountProtocol>(provider: GigyaSocialProviders, viewController: UIViewController, params: [String: Any], dataType: T.Type, completion: @escaping (GigyaApiResult<T>) -> Void) {
        GigyaLogger.log(with: self, message: "[addConnection] - start")

        providerAdapter = socialProviderFactory.getProvider(with: provider, delegate: self)
        providerAdapter?.login(type: T.self, params: params, viewController: viewController, loginMode: "connect") { (res) in
            completion(res)

            GigyaLogger.log(with: self, message: "[addConnection] - finish: \(res)")
        }
        
        providerAdapter?.didFinish = { [weak self] in
            self?.clearOptionalObjects()
        }
    }
    
    func removeConnection(params: [String: Any], completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        GigyaLogger.log(with: self, message: "[removeConnection]: params: \(params)")

        let model = ApiRequestModel(method: GigyaDefinitions.API.removeConnection, params: params)
        apiService.send(model: model, responseType: GigyaDictionary.self, completion: completion)
    }
    
    func removeConnection(providerName: GigyaSocialProviders, completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        let params = ["provider": providerName.rawValue]

        GigyaLogger.log(with: self, message: "[removeConnection]: params: \(params)")

        let model = ApiRequestModel(method: GigyaDefinitions.API.removeConnection, params: params)
        apiService.send(model: model, responseType: GigyaDictionary.self, completion: completion)
    }
    
    func logout(completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        GigyaLogger.log(with: self, message: "[logout]")

        let model = ApiRequestModel(method: GigyaDefinitions.API.logout, params: [:])
        apiService.send(model: model, responseType: GigyaDictionary.self) { [weak self] result in
            self?.sessionService.clear()
            self?.sessionService.clearCookies()
            self?.biometricService.clearBiometric()
            
            switch result {
            case .success(let data):
                completion(.success(data: data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func finalizeRegistration<T: Codable>(regToken: String, completion: @escaping (GigyaLoginResult<T>) -> Void) {
        let params = ["regToken": regToken, "include": "profile,data,emails,subscriptions,preferences", "includeUserInfo": "true"]

        GigyaLogger.log(with: self, message: "[finalizeRegistration] - params: \(params)")

        send(dataType: T.self, api: GigyaDefinitions.API.finalizeRegistration, params: params) { [weak accountService] result in
            switch result {
            case .success(let data):
                accountService?.account = data
                completion(.success(data: data))

                GigyaLogger.log(with: BusinessApiService.self, message: "[finalizeRegistration] - success")
            case .failure(let error):
                self.interruptionResolver(error: error, completion: completion)
            }
        }
    }

    func forgotPassword(params: [String: Any], completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.resetPassword, params: params)
        apiService.send(model: model, responseType: GigyaDictionary.self, completion: completion)
    }

    // MARK: - Api methods

    func isAvailable(loginId: String, completion: @escaping (GigyaApiResult<Bool>) -> Void) {
        var params: [String: Any] = [:]
        params["loginID"] = loginId

        let model = ApiRequestModel(method: GigyaDefinitions.API.isAvailableLoginID, params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self) { result in
            switch result {
            case .success(let result):
                let isAvailble = result["isAvailable"]?.value as? Bool ?? false
                completion(.success(data: isAvailble))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func getSchema(params: [String: Any], completion: @escaping (GigyaApiResult<GigyaSchema>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.getSchema, params: params)

        apiService.send(model: model, responseType: GigyaSchema.self) { result in
            switch result {
            case .success(let data):
                completion(.success(data: data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func verifySession(params: [String: Any], completion: @escaping (GigyaApiResult<GigyaDictionary>) -> Void) {
        let model = ApiRequestModel(method: GigyaDefinitions.API.isSessionValid, params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self) { result in
            switch result {
            case .success(let data):
                completion(.success(data: data))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    func getAuthCode(completion: @escaping (GigyaApiResult<String>) -> Void) {
        let params = ["resource": "urn:gigya:account",
                      "subject_token_type": "urn:gigya:token-type:mobile",
                      "response_type": "code"
        ]
        let model = ApiRequestModel(method: "accounts.identity.token.exchange", params: params)

        apiService.send(model: model, responseType: GigyaDictionary.self) { result in
            switch result {
            case .success(let data):
                let code = data["code"]?.value as? String ?? ""
                completion(.success(data: code))
            case .failure(let error):
                completion(.failure(error))
            }
        }

    }
    
    @available(iOS 13.0, *)
    func getSaptchaToken(completion: @escaping (GigyaApiResult<String>) -> Void) {
        saptchaService = SaptchaService(businessApiService: self, saptchaUtils: SaptchaUtils())
        saptchaService?.startChallenge(completion: completion)
    }

    // MARK: - Internal methods

    func interruptionResolver<T: GigyaAccountProtocol>(error: NetworkError, completion: @escaping (GigyaLoginResult<T>) -> Void, model: ApiRequestModel? = nil) {
        interruptionsHandler.resolve(error: error, businessDelegate: self, completion: completion, model: model)
    }

    private func clearOptionalObjects() {
        self.providerAdapter = nil
    }

    private func dismissProvidersLogin() {
        self.providersFactory?.dismiss()
        self.providersFactory = nil
    }
}
