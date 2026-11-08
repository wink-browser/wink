#import "WinkInternal.h"

namespace wink {

CefRefPtr<CefValue> ToCefValue(id object) {
  CefRefPtr<CefValue> value = CefValue::Create();
  if (!object || object == [NSNull null]) {
    value->SetNull();
  } else if ([object isKindOfClass:[NSString class]]) {
    value->SetString(ToCef(object));
  } else if ([object isKindOfClass:[NSNumber class]]) {
    NSNumber* number = object;
    if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
      value->SetBool(number.boolValue);
    } else if (CFNumberIsFloatType((__bridge CFNumberRef)number)) {
      value->SetDouble(number.doubleValue);
    } else {
      value->SetInt(number.intValue);
    }
  } else if ([object isKindOfClass:[NSArray class]]) {
    CefRefPtr<CefListValue> list = CefListValue::Create();
    NSArray* array = object;
    list->SetSize(array.count);
    for (NSUInteger i = 0; i < array.count; ++i) list->SetValue(i, ToCefValue(array[i]));
    value->SetList(list);
  } else if ([object isKindOfClass:[NSDictionary class]]) {
    CefRefPtr<CefDictionaryValue> dict = CefDictionaryValue::Create();
    [(NSDictionary*)object enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL*) {
      dict->SetValue(ToCef([key description]), ToCefValue(obj));
    }];
    value->SetDictionary(dict);
  } else {
    value->SetString(ToCef([object description]));
  }
  return value;
}

id FromCefValue(CefRefPtr<CefValue> value) {
  if (!value) return nil;
  switch (value->GetType()) {
    case VTYPE_BOOL: return @(value->GetBool());
    case VTYPE_INT: return @(value->GetInt());
    case VTYPE_DOUBLE: return @(value->GetDouble());
    case VTYPE_STRING: return ToNS(value->GetString());
    case VTYPE_LIST: {
      CefRefPtr<CefListValue> list = value->GetList();
      NSMutableArray* out = [NSMutableArray arrayWithCapacity:list->GetSize()];
      for (size_t i = 0; i < list->GetSize(); ++i) out[i] = FromCefValue(list->GetValue(i)) ?: [NSNull null];
      return out;
    }
    case VTYPE_DICTIONARY: {
      CefRefPtr<CefDictionaryValue> dict = value->GetDictionary();
      CefDictionaryValue::KeyList keys;
      dict->GetKeys(keys);
      NSMutableDictionary* out = [NSMutableDictionary dictionaryWithCapacity:keys.size()];
      for (const auto& key : keys) out[ToNS(key)] = FromCefValue(dict->GetValue(key)) ?: [NSNull null];
      return out;
    }
    case VTYPE_NULL: return [NSNull null];
    default: return nil;
  }
}

}  // namespace wink
