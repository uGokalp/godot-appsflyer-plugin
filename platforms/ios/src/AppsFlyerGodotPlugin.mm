#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <AppsFlyerLib/AppsFlyerLib-Swift.h>
#import <AppsFlyerLib/AppsFlyerLib.h>
#import <UIKit/UIKit.h>

#import "drivers/apple_embedded/godot_app_delegate.h"

#include "session_gate.h"

#include "core/config/engine.h"
#include "core/object/class_db.h"

#include <cmath>

// Godot strings can hold lone surrogates, which are invalid UTF-8 and make Foundation return nil.
static NSString *to_ns_string(const String &p_string) {
	return [NSString stringWithUTF8String:p_string.utf8().get_data()] ?: @"";
}

static String to_godot_string(NSString *p_string) {
	return p_string ? String::utf8(p_string.UTF8String) : String();
}

static Variant to_variant(id p_value) {
	if (p_value == nil || p_value == NSNull.null) {
		return Variant();
	}
	if ([p_value isKindOfClass:NSString.class]) {
		return to_godot_string(p_value);
	}
	if ([p_value isKindOfClass:NSNumber.class]) {
		CFTypeRef number = (__bridge CFTypeRef)p_value;
		if (CFGetTypeID(number) == CFBooleanGetTypeID()) {
			return (bool)[p_value boolValue];
		}
		if (CFNumberIsFloatType((CFNumberRef)number)) {
			return [p_value doubleValue];
		}
		if (*[p_value objCType] == 'Q' && [p_value unsignedLongLongValue] > INT64_MAX) {
			return [p_value doubleValue];
		}
		return (int64_t)[p_value longLongValue];
	}
	if ([p_value isKindOfClass:NSDictionary.class]) {
		NSDictionary *dictionary = p_value;
		Dictionary result;
		for (id key in dictionary) {
			result[to_godot_string([key description])] = to_variant(dictionary[key]);
		}
		return result;
	}
	if ([p_value isKindOfClass:NSArray.class]) {
		Array result;
		for (id object in (NSArray *)p_value) {
			result.push_back(to_variant(object));
		}
		return result;
	}
	return to_godot_string([p_value description]);
}

static id to_ns_object(const Variant &p_value) {
	switch (p_value.get_type()) {
		case Variant::NIL:
			return NSNull.null;
		case Variant::BOOL:
			return @((bool)p_value);
		case Variant::INT:
			return @((int64_t)p_value);
		case Variant::FLOAT: {
			double value = p_value;
			// JSON has no NaN or infinity; the SDK would fail to serialize the whole payload.
			return std::isfinite(value) ? @(value) : NSNull.null;
		}
		case Variant::DICTIONARY: {
			Dictionary dictionary = p_value;
			NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:dictionary.size()];
			for (const KeyValue<Variant, Variant> &entry : dictionary) {
				result[to_ns_string(entry.key)] = to_ns_object(entry.value);
			}
			return result;
		}
		case Variant::ARRAY:
		case Variant::PACKED_BYTE_ARRAY:
		case Variant::PACKED_INT32_ARRAY:
		case Variant::PACKED_INT64_ARRAY:
		case Variant::PACKED_FLOAT32_ARRAY:
		case Variant::PACKED_FLOAT64_ARRAY:
		case Variant::PACKED_STRING_ARRAY: {
			Array array = p_value;
			NSMutableArray *result = [NSMutableArray arrayWithCapacity:array.size()];
			for (const Variant &item : array) {
				[result addObject:to_ns_object(item)];
			}
			return result;
		}
		default:
			return to_ns_string(p_value);
	}
}

@interface AppsFlyerGodotService : NSObject <UIApplicationDelegate, UIWindowSceneDelegate, AppsFlyerLibDelegate, AppsFlyerDeepLinkDelegate>
@property(nonatomic, readonly, class) AppsFlyerGodotService *shared;
- (void)attachToSDK;
@end

class AppsFlyerGodotPlugin : public Object {
	GDCLASS(AppsFlyerGodotPlugin, Object);

	static inline AppsFlyerGodotPlugin *singleton = nullptr;

	bool initialized = false;
	bool debug = false;
	bool skan_disabled = false;
	bool stopped = false;
	bool anonymized = false;
	bool tcf_collection = false;
	AppsFlyerConsent *consent = nil;
	String customer_user_id;
	SessionGate gate;

	static NSNumber *to_optional_bool(const Variant &p_value) {
		return p_value.get_type() == Variant::NIL ? nil : @((bool)p_value);
	}

	static void start_if(bool p_release) {
		if (p_release) {
			[AppsFlyerLib.shared start];
		}
	}

	static void on_main_with_plugin(void (^p_block)(AppsFlyerGodotPlugin *)) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (singleton) {
				p_block(singleton);
			}
		});
	}

	// ATT requested from inside the become-active notification can return notDetermined without
	// showing the prompt, so run on the next main-queue turn and only if the app is still active.
	static void when_next_active(dispatch_block_t p_block) {
		__block id observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
																			  object:nil
																			   queue:NSOperationQueue.mainQueue
																		  usingBlock:^(NSNotification *) {
																			  [NSNotificationCenter.defaultCenter removeObserver:observer];
																			  observer = nil;
																			  dispatch_async(dispatch_get_main_queue(), ^{
																				  if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
																					  p_block();
																				  } else {
																					  when_next_active(p_block);
																				  }
																			  });
																		  }];
	}

	static void request_att(uint64_t p_generation) {
		[ATTrackingManager requestTrackingAuthorizationWithCompletionHandler:^(ATTrackingManagerAuthorizationStatus status) {
			on_main_with_plugin(^(AppsFlyerGodotPlugin *plugin) {
				if (status == ATTrackingManagerAuthorizationStatusNotDetermined) {
					// The prompt was suppressed (app inactive or another permission dialog showing).
					if (plugin->gate.retry_undetermined_consent(p_generation)) {
						dispatch_block_t retry = ^{
							if (singleton && singleton->gate.begin_consent_retry(p_generation)) {
								request_att(p_generation);
							}
						};
						when_next_active(retry);
						// Activation may have already happened before the completion reached main. While the app is
						// still inactive, the dialog that suppressed ATT is up and the next activation retries.
						dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
							if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
								retry();
							}
						});
					} else {
						start_if(plugin->gate.resolve_consent(p_generation));
					}
					return;
				}
				plugin->emit_signal("att_status_received", (int)status);
				start_if(plugin->gate.resolve_consent(p_generation));
			});
		}];
	}

protected:
	static void _bind_methods() {
		ClassDB::bind_method(D_METHOD("init", "dev_key", "apple_app_id", "onelink_custom_domains"), &AppsFlyerGodotPlugin::init);
		ClassDB::bind_method(D_METHOD("start"), &AppsFlyerGodotPlugin::start);
		ClassDB::bind_method(D_METHOD("set_customer_user_id", "id"), &AppsFlyerGodotPlugin::set_customer_user_id);
		ClassDB::bind_method(D_METHOD("set_debug", "enabled"), &AppsFlyerGodotPlugin::set_debug);
		ClassDB::bind_method(D_METHOD("disable_skan", "disabled"), &AppsFlyerGodotPlugin::disable_skan);
		ClassDB::bind_method(D_METHOD("set_stopped", "stopped"), &AppsFlyerGodotPlugin::set_stopped);
		ClassDB::bind_method(D_METHOD("is_stopped"), &AppsFlyerGodotPlugin::is_stopped);
		ClassDB::bind_method(D_METHOD("set_anonymize_user", "enabled"), &AppsFlyerGodotPlugin::set_anonymize_user);
		ClassDB::bind_method(D_METHOD("set_consent", "subject_to_gdpr", "data_usage", "ads_personalization", "ad_storage"), &AppsFlyerGodotPlugin::set_consent);
		ClassDB::bind_method(D_METHOD("enable_tcf_data_collection", "enabled"), &AppsFlyerGodotPlugin::enable_tcf_data_collection);
		ClassDB::bind_method(D_METHOD("log_ad_revenue", "monetization_network", "mediation_network", "currency", "revenue", "params"), &AppsFlyerGodotPlugin::log_ad_revenue);
		ClassDB::bind_method(D_METHOD("request_tracking_authorization", "timeout_sec"), &AppsFlyerGodotPlugin::request_tracking_authorization);
		ClassDB::bind_method(D_METHOD("get_att_status"), &AppsFlyerGodotPlugin::get_att_status);
		ClassDB::bind_method(D_METHOD("log_event", "name", "params"), &AppsFlyerGodotPlugin::log_event);
		ClassDB::bind_method(D_METHOD("get_appsflyer_id"), &AppsFlyerGodotPlugin::get_appsflyer_id);

		ADD_SIGNAL(MethodInfo("conversion_data_received", PropertyInfo(Variant::DICTIONARY, "data")));
		ADD_SIGNAL(MethodInfo("conversion_data_failed", PropertyInfo(Variant::STRING, "error")));
		ADD_SIGNAL(MethodInfo("deep_link_received", PropertyInfo(Variant::DICTIONARY, "result")));
		ADD_SIGNAL(MethodInfo("att_status_received", PropertyInfo(Variant::INT, "status")));
		ADD_SIGNAL(MethodInfo("event_logged", PropertyInfo(Variant::STRING, "name"), PropertyInfo(Variant::BOOL, "success"), PropertyInfo(Variant::INT, "error_code")));
	}

public:
	static AppsFlyerGodotPlugin *get_singleton() { return singleton; }

	template <typename... Args>
	static void emit_on_main(const char *p_signal, Args... p_args) {
		dispatch_async(dispatch_get_main_queue(), [=] {
			if (singleton) {
				singleton->emit_signal(p_signal, p_args...);
			}
		});
	}

	void init(const String &p_dev_key, const String &p_apple_app_id, const PackedStringArray &p_onelink_custom_domains) {
		ERR_FAIL_COND_MSG(initialized, "AppsFlyer: init() was already called.");
		ERR_FAIL_COND_MSG(p_dev_key.is_empty() || p_apple_app_id.is_empty(), "AppsFlyer: dev key and Apple app id are required.");

		AppsFlyerLib *sdk = AppsFlyerLib.shared;
		[sdk initWithDevKey:to_ns_string(p_dev_key) appleAppId:to_ns_string(p_apple_app_id)];
		sdk.isDebug = debug;
		sdk.disableSKAdNetwork = skan_disabled;
		sdk.isStopped = stopped;
		sdk.anonymizeUser = anonymized;
		if (tcf_collection) {
			[sdk enableTCFDataCollection:YES];
		}
		if (consent) {
			[sdk setConsentData:consent];
		}
		if (!customer_user_id.is_empty()) {
			sdk.customerUserID = to_ns_string(customer_user_id);
		}
		if (!p_onelink_custom_domains.is_empty()) {
			NSMutableArray<NSString *> *domains = [NSMutableArray arrayWithCapacity:p_onelink_custom_domains.size()];
			for (const String &domain : p_onelink_custom_domains) {
				[domains addObject:to_ns_string(domain)];
			}
			sdk.oneLinkCustomDomains = domains;
		}
		initialized = true;

		[AppsFlyerGodotService.shared attachToSDK];
		[sdk registerSessionReadyListener:^{
			on_main_with_plugin(^(AppsFlyerGodotPlugin *plugin) {
				start_if(plugin->gate.on_session_ready(UIApplication.sharedApplication.applicationState == UIApplicationStateBackground));
			});
		}];
	}

	void start() { start_if(gate.request_start()); }

	void on_background() { gate.on_background(); }

	void set_customer_user_id(const String &p_id) {
		customer_user_id = p_id;
		if (initialized) {
			AppsFlyerLib.shared.customerUserID = p_id.is_empty() ? nil : to_ns_string(p_id);
		}
	}

	void set_debug(bool p_enabled) {
		debug = p_enabled;
		if (initialized) {
			AppsFlyerLib.shared.isDebug = p_enabled;
		}
	}

	void disable_skan(bool p_disabled) {
		skan_disabled = p_disabled;
		if (initialized) {
			AppsFlyerLib.shared.disableSKAdNetwork = p_disabled;
		}
	}

	void set_stopped(bool p_stopped) {
		stopped = p_stopped;
		if (initialized) {
			AppsFlyerLib.shared.isStopped = p_stopped;
		}
	}

	bool is_stopped() { return stopped; }

	void set_anonymize_user(bool p_enabled) {
		anonymized = p_enabled;
		if (initialized) {
			AppsFlyerLib.shared.anonymizeUser = p_enabled;
		}
	}

	void set_consent(bool p_subject_to_gdpr, const Variant &p_data_usage, const Variant &p_ads_personalization, const Variant &p_ad_storage) {
		consent = [[AppsFlyerConsent alloc] initWithIsUserSubjectToGDPR:@(p_subject_to_gdpr)
												 hasConsentForDataUsage:to_optional_bool(p_data_usage)
										hasConsentForAdsPersonalization:to_optional_bool(p_ads_personalization)
												 hasConsentForAdStorage:to_optional_bool(p_ad_storage)];
		if (initialized) {
			[AppsFlyerLib.shared setConsentData:consent];
		}
	}

	void enable_tcf_data_collection(bool p_enabled) {
		tcf_collection = p_enabled;
		if (initialized) {
			[AppsFlyerLib.shared enableTCFDataCollection:p_enabled];
		}
	}

	void log_ad_revenue(const String &p_monetization_network, int p_mediation_network, const String &p_currency, double p_revenue, const Dictionary &p_params) {
		ERR_FAIL_COND_MSG(!initialized, "AppsFlyer: call init() before log_ad_revenue().");
		ERR_FAIL_COND_MSG(p_mediation_network < AppsFlyerAdRevenueMediationNetworkTypeGoogleAdMob || p_mediation_network > AppsFlyerAdRevenueMediationNetworkTypeDirectMonetization,
				"AppsFlyer: unknown mediation network.");
		ERR_FAIL_COND_MSG(!std::isfinite(p_revenue), "AppsFlyer: ad revenue must be a finite number.");
		AFAdRevenueData *data = [[AFAdRevenueData alloc] initWithMonetizationNetwork:to_ns_string(p_monetization_network)
																   mediationNetwork:(AppsFlyerAdRevenueMediationNetworkType)p_mediation_network
																currencyIso4217Code:to_ns_string(p_currency)
																	   eventRevenue:@(p_revenue)];
		[AppsFlyerLib.shared logAdRevenue:data additionalParameters:p_params.is_empty() ? nil : to_ns_object(p_params)];
	}

	bool request_tracking_authorization(double p_timeout_sec) {
		ERR_FAIL_NULL_V_MSG([NSBundle.mainBundle objectForInfoDictionaryKey:@"NSUserTrackingUsageDescription"], false,
				"AppsFlyer: NSUserTrackingUsageDescription is missing. Set appsflyer/config/att_usage_description and re-export.");
		if (gate.awaiting_consent) {
			return true;
		}

		uint64_t generation = gate.begin_consent();
		if (p_timeout_sec > 0.0) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(p_timeout_sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
				if (singleton) {
					start_if(singleton->gate.resolve_consent(generation));
				}
			});
		}
		if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
			request_att(generation);
		} else {
			when_next_active(^{
				request_att(generation);
			});
		}
		return true;
	}

	int get_att_status() {
		return (int)ATTrackingManager.trackingAuthorizationStatus;
	}

	void log_event(const String &p_name, const Dictionary &p_params) {
		ERR_FAIL_COND_MSG(!initialized, "AppsFlyer: call init() before log_event().");
		String name = p_name;
		[AppsFlyerLib.shared logEventWithEventName:to_ns_string(p_name)
									   eventValues:to_ns_object(p_params)
								 completionHandler:^(NSDictionary *, NSError *error) {
									 emit_on_main("event_logged", name, error == nil, error ? (int)error.code : 0);
								 }];
	}

	String get_appsflyer_id() {
		return initialized ? to_godot_string(AppsFlyerLib.shared.getAppsFlyerUID) : String();
	}

	AppsFlyerGodotPlugin() { singleton = this; }
	~AppsFlyerGodotPlugin() { singleton = nullptr; }
};

@implementation AppsFlyerGodotService {
	NSDictionary *_launchOptions;
	NSMutableArray<dispatch_block_t> *_pendingLinks;
	BOOL _attached;
}

+ (AppsFlyerGodotService *)shared {
	static AppsFlyerGodotService *shared = [AppsFlyerGodotService new];
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_pendingLinks = [NSMutableArray new];
	}
	return self;
}

- (void)attachToSDK {
	AppsFlyerLib *sdk = AppsFlyerLib.shared;
	sdk.delegate = self;
	sdk.deepLinkDelegate = self;
	[sdk handleLaunchOptions:_launchOptions];
	_launchOptions = nil;
	_attached = YES;
	for (dispatch_block_t forward in _pendingLinks) {
		forward();
	}
	[_pendingLinks removeAllObjects];
}

- (void)forward:(dispatch_block_t)link {
	if (_attached) {
		link();
	} else {
		[_pendingLinks addObject:link];
	}
}

- (void)forwardActivity:(NSUserActivity *)activity {
	[self forward:^{
		[AppsFlyerLib.shared continueUserActivity:activity restorationHandler:nil];
	}];
}

- (void)forwardURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
	for (UIOpenURLContext *context in contexts) {
		NSString *source = context.options.sourceApplication;
		NSDictionary *options = source ? @{ UIApplicationOpenURLOptionsSourceApplicationKey : source } : @{};
		[self forward:^{
			[AppsFlyerLib.shared handleOpenUrl:context.URL options:options];
		}];
	}
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	_launchOptions = launchOptions;
	return NO;
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
	for (NSUserActivity *activity in options.userActivities) {
		if (!_attached && [activity.activityType isEqualToString:NSUserActivityTypeBrowsingWeb] && !_launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey]) {
			// Scene apps never get a cold Universal Link in the launch options; rebuild what UIKit passes
			// non-scene apps so the SDK's session readiness waits for the link to resolve.
			NSMutableDictionary *launchOptions = [NSMutableDictionary dictionaryWithDictionary:_launchOptions ?: @{}];
			launchOptions[UIApplicationLaunchOptionsUserActivityDictionaryKey] = @{
				UIApplicationLaunchOptionsUserActivityTypeKey : activity.activityType,
				@"UIApplicationLaunchOptionsUserActivityKey" : activity,
			};
			_launchOptions = launchOptions;
		}
		[self forwardActivity:activity];
	}
	[self forwardURLContexts:options.URLContexts];
}

- (void)scene:(UIScene *)scene continueUserActivity:(NSUserActivity *)activity {
	[self forwardActivity:activity];
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
	[self forwardURLContexts:contexts];
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
	if (AppsFlyerGodotPlugin *plugin = AppsFlyerGodotPlugin::get_singleton()) {
		plugin->on_background();
	}
}

- (void)onConversionDataSuccess:(NSDictionary *)conversionInfo {
	AppsFlyerGodotPlugin::emit_on_main("conversion_data_received", to_variant(conversionInfo));
}

- (void)onConversionDataFail:(NSError *)error {
	AppsFlyerGodotPlugin::emit_on_main("conversion_data_failed", to_godot_string(error.localizedDescription));
}

- (void)didResolveDeepLink:(AppsFlyerDeepLinkResult *)result {
	static const char *statuses[] = { "not_found", "found", "failure" };
	AppsFlyerDeepLink *link = result.deepLink;
	Dictionary data;
	data["status"] = statuses[result.status];
	data["deeplink_value"] = to_variant(link.deeplinkValue);
	data["is_deferred"] = link != nil && link.isDeferred;
	data["click_event"] = link ? to_variant(link.clickEvent) : Variant(Dictionary());
	if (result.error) {
		data["error"] = to_godot_string(result.error.localizedDescription);
	}
	AppsFlyerGodotPlugin::emit_on_main("deep_link_received", data);
}

@end

// The service must be registered before UIApplicationMain dispatches launch callbacks, and Godot
// enumerates its services while calling plugin initializers, so registering there would mutate
// the array mid-enumeration. Static initializers run after every +load (which creates the array).
__attribute__((constructor)) static void register_appsflyer_service() {
	[GDTApplicationDelegate addService:AppsFlyerGodotService.shared];
}

void init_appsflyer_plugin() {
	Engine::get_singleton()->add_singleton(Engine::Singleton("AppsFlyerGodotPlugin", memnew(AppsFlyerGodotPlugin)));
}

void deinit_appsflyer_plugin() {
	if (AppsFlyerGodotPlugin *plugin = AppsFlyerGodotPlugin::get_singleton()) {
		memdelete(plugin);
	}
}
