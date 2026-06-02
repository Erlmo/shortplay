#ifndef WEEOU_SIGN_H
#define WEEOU_SIGN_H

#ifdef __cplusplus
extern "C" {
#endif

int weeou_sign(const char *method, const char *path,
               const char *query, const char *body, int body_len,
               char *out_buf);

#ifdef __cplusplus
}
#endif

#endif /* WEEOU_SIGN_H */
