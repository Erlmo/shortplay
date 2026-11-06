#include <jni.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>

namespace {
struct Api {
  void* lib = nullptr;
  void* (*param)() = nullptr;
  void* (*packet)() = nullptr;
  void* (*frame)() = nullptr;
  int (*setParam)(void*, const char*, int64_t) = nullptr;
  int (*setInt)(void*, const char*, int64_t) = nullptr;
  int (*setPtr)(void*, const char*, void*) = nullptr;
  void* (*create)(void*) = nullptr;
  void (*destroy)(void*) = nullptr;
  void (*freeParam)(void*) = nullptr;
  void (*freePacket)(void*) = nullptr;
  void (*freeFrame)(void*) = nullptr;
  int (*decode)(void*, void*, void*) = nullptr;
  int64_t (*info)(void*, const char*, int) = nullptr;
  void* (*plane)(void*, const char*, int) = nullptr;
};
Api api;
std::once_flag loaded;
bool available() {
  std::call_once(loaded, [] {
#if defined(__aarch64__) || defined(__arm__)
    api.lib = dlopen("libbyteVC2dec.so", RTLD_NOW | RTLD_LOCAL);
    if (!api.lib) return;
#define SYM(field, name) api.field = reinterpret_cast<decltype(api.field)>(dlsym(api.lib, name))
    SYM(param,"byteVC2dec_get_default_param"); SYM(packet,"byteVC2dec_alloc_packet");
    SYM(frame,"byteVC2dec_alloc_frame"); SYM(setParam,"byteVC2dec_set_param_integer_info");
    SYM(setInt,"byteVC2dec_set_packet_integer_info"); SYM(setPtr,"byteVC2dec_set_packet_pointer_info");
    SYM(create,"byteVC2dec_create"); SYM(destroy,"byteVC2dec_destroy");
    SYM(freeParam,"byteVC2dec_release_param"); SYM(freePacket,"byteVC2dec_release_packet");
    SYM(freeFrame,"byteVC2dec_release_frame"); SYM(decode,"byteVC2dec_decode");
    SYM(info,"byteVC2dec_get_frame_integer_info"); SYM(plane,"byteVC2dec_get_frame_pointer_info");
#undef SYM
#endif
  });
  return api.param && api.packet && api.frame && api.setParam && api.setInt && api.setPtr &&
      api.create && api.destroy && api.freeParam && api.freePacket && api.freeFrame &&
      api.decode && api.info && api.plane;
}
struct Decoder {
  void* params = nullptr;
  void* context = nullptr;
  void* packet = nullptr;
  void* frame = nullptr;
  std::vector<uint8_t> input;
  ~Decoder() {
    if (context) api.destroy(context);
    if (frame) api.freeFrame(frame);
    if (packet) api.freePacket(packet);
    if (params) api.freeParam(params);
  }
  int feed(const uint8_t* bytes, int size, int64_t pts) {
    // 解码器内部 SIMD 读取要求尾部 padding；不能直接借用 Java 缓冲。
    input.assign(static_cast<size_t>(size) + 64, 0);
    if (size) std::memcpy(input.data(), bytes, size);
    api.setPtr(packet,"bs",size ? input.data() : nullptr);
    api.setInt(packet,"bs_len",size);
    api.setInt(packet,"pts",pts);
    api.setInt(packet,"flag",0);
    return api.decode(context,packet,frame);
  }
};
void error(JNIEnv* env,const char* message) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"),message);
}
int clamp(int value) { return std::max(0, std::min(255, value)); }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_shortplay_bvc2_Bvc2Native_available(JNIEnv*,jclass) { return available(); }

extern "C" JNIEXPORT jlong JNICALL
Java_com_example_shortplay_bvc2_Bvc2Native_create(JNIEnv* env,jclass,jbyteArray config) {
  if (!available()) { error(env,"BVC2 decoder is unavailable on this ABI"); return 0; }
  auto* d = new Decoder();
  d->params=api.param();
  if (d->params) {
    api.setParam(d->params,"threads",2);
    api.setParam(d->params,"parallel_frames",1);
#if defined(__aarch64__)
    api.setParam(d->params,"gpu_mode",0);
#endif
    api.setParam(d->params,"output_method",0);
    api.setParam(d->params,"wpp_mode",0);
    d->packet=api.packet(); d->frame=api.frame(); d->context=api.create(d->params);
  }
  if (!d->params || !d->packet || !d->frame || !d->context) {
    delete d; error(env,"Could not initialize BVC2 decoder"); return 0;
  }
  int n=env->GetArrayLength(config);
  std::vector<uint8_t> bytes(n);
  env->GetByteArrayRegion(config,0,n,reinterpret_cast<jbyte*>(bytes.data()));
  if (n && d->feed(bytes.data(),n,0)!=0) {
    delete d; error(env,"Could not decode BVC2 configuration"); return 0;
  }
  return reinterpret_cast<jlong>(d);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_shortplay_bvc2_Bvc2Native_decode(JNIEnv* env,jclass,jlong handle,
    jobject input,jint offset,jint size,jlong pts,jobject output) {
  auto* d=reinterpret_cast<Decoder*>(handle);
  if (!d || size<0 || size>16*1024*1024 || offset<0) { error(env,"Invalid BVC2 packet"); return false; }
  auto* bytes=input ? static_cast<uint8_t*>(env->GetDirectBufferAddress(input)) : nullptr;
  if (size && (!bytes || static_cast<int64_t>(offset)+size>env->GetDirectBufferCapacity(input))) {
    error(env,"Invalid BVC2 input buffer"); return false;
  }
  if (d->feed(size ? bytes+offset : nullptr,size,pts)!=0) { error(env,"BVC2 packet decode failed"); return false; }
  if (!api.info(d->frame,"got_frame",0)) return false;
  int w=api.info(d->frame,"width",0),h=api.info(d->frame,"height",0);
  if (w<=0 || h<=0 || w>4096 || h>4096 || api.info(d->frame,"bit_depth",0)!=8) {
    error(env,"Unsupported BVC2 frame dimensions or bit depth"); return false;
  }
  int cw=(w+1)/2,ch=(h+1)/2;
  jclass cls=env->GetObjectClass(output);
  if (!cls || env->ExceptionCheck()) return false;
  int color=api.info(d->frame,"color_space",0)==1 ? 2 : 1;
  auto init=env->GetMethodID(cls,"initForYuvFrame","(IIIII)Z");
  if (!init || env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
  jfieldID dataField=env->GetFieldID(cls,"data","Ljava/nio/ByteBuffer;");
  if (!dataField || env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
  jfieldID timeField=env->GetFieldID(cls,"timeUs","J");
  if (!timeField || env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
  jfieldID rangeField=env->GetFieldID(cls,"decoderPrivate","I");
  if (!rangeField || env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
  jboolean initialized=env->CallBooleanMethod(output,init,w,h,w,cw,color);
  if (env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
  if (!initialized) { env->DeleteLocalRef(cls); error(env,"BVC2 frame allocation failed"); return false; }
  jobject data=env->GetObjectField(output,dataField);
  if (!data || env->ExceptionCheck()) { env->DeleteLocalRef(cls); return false; }
  auto* target=static_cast<uint8_t*>(env->GetDirectBufferAddress(data));
  if (!target || env->GetDirectBufferCapacity(data)<static_cast<int64_t>(w)*h+2LL*cw*ch) {
    env->DeleteLocalRef(data); env->DeleteLocalRef(cls);
    error(env,"Invalid BVC2 frame buffer"); return false;
  }
  for(int i=0;i<3;i++) {
    auto* src=static_cast<uint8_t*>(api.plane(d->frame,"data",i));
    int stride=api.info(d->frame,"linesize",i),width=i?cw:w,height=i?ch:h;
    if (!src || stride<width) {
      env->DeleteLocalRef(data); env->DeleteLocalRef(cls);
      error(env,"Invalid BVC2 frame planes"); return false;
    }
    for(int y=0;y<height;y++) std::memcpy(target+y*width,src+y*stride,width);
    target+=width*height;
  }
  env->SetLongField(output,timeField,api.info(d->frame,"pts",0));
  env->SetIntField(output,rangeField,api.info(d->frame,"video_full_range_flag",0)?1:0);
  env->DeleteLocalRef(data); env->DeleteLocalRef(cls);
  return true;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_shortplay_bvc2_Bvc2Native_destroy(JNIEnv*,jclass,jlong handle) {
  delete reinterpret_cast<Decoder*>(handle);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_shortplay_bvc2_Bvc2Native_render(JNIEnv* env,jclass,jobject data,
    jint w,jint h,jint color,jboolean full,jobject surface) {
  auto* y=static_cast<uint8_t*>(env->GetDirectBufferAddress(data));
  int cw=(w+1)/2,ch=(h+1)/2;
  if (!y || w<=0 || h<=0 || w>4096 || h>4096 ||
      env->GetDirectBufferCapacity(data)<static_cast<int64_t>(w)*h+2LL*cw*ch) { error(env,"Invalid BVC2 output buffer"); return; }
  auto* u=y+w*h;auto* v=u+cw*ch;
  ANativeWindow* window=ANativeWindow_fromSurface(env,surface);
  if(!window){error(env,"BVC2 surface is unavailable");return;}
  ANativeWindow_setBuffersGeometry(window,w,h,WINDOW_FORMAT_RGBA_8888);
  ANativeWindow_Buffer frame;
  if(ANativeWindow_lock(window,&frame,nullptr)!=0){ANativeWindow_release(window);error(env,"Could not lock BVC2 surface");return;}
  for(int row=0;row<h;row++) {
    auto* dest=static_cast<uint8_t*>(frame.bits)+row*frame.stride*4;
    for(int x=0;x<w;x++) {
      int yy=y[row*w+x],uu=u[(row/2)*cw+x/2]-128,vv=v[(row/2)*cw+x/2]-128;
      int base=full?256*yy:298*std::max(0,yy-16);
      int cr=full?(color==2?403:359):(color==2?459:409);
      int gu=full?(color==2?48:88):(color==2?55:100);
      int gv=full?(color==2?120:183):(color==2?136:208);
      int cb=full?(color==2?475:454):(color==2?541:516);
      dest[4*x]=clamp((base+cr*vv+128)>>8);
      dest[4*x+1]=clamp((base-gu*uu-gv*vv+128)>>8);
      dest[4*x+2]=clamp((base+cb*uu+128)>>8);dest[4*x+3]=255;
    }
  }
  ANativeWindow_unlockAndPost(window);ANativeWindow_release(window);
}
