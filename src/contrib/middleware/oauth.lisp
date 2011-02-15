(in-package :cl-user)

(defpackage clack.middleware.oauth
  (:use . (:cl
           :anaphora
           :metabang-bind
           :clack.component
           :clack.request
           :clack.response
           :clack.middleware))
  (:export :<clack-middleware-oauth>))

(in-package :clack.middleware.oauth)

(defclass <clack-middleware-oauth> (<middleware>)
     ((path :initarg :path :accessor oauth-path)
      (callback-base :initarg :callback-base :accessor oauth-callback-base)
      (consumer-key :initarg :consumer-key :accessor oauth-consumer-key)
      (consumer-secret :initarg :consumer-secret :accessor oauth-consumer-secret)
      (authorize-uri :initarg :authorize-uri :accessor oauth-authorize-uri)
      (request-token-uri :initarg :request-token-uri :accessor oauth-request-token-uri)
      (access-token-uri :initarg :access-token-uri :accessor oauth-access-token-uri)
      (authorized :initarg :authorized :accessor oauth-authorized)
      (state :initform (make-hash-table :test #'equal) :accessor oauth-state)
      (state-expire :initarg :state-expire :initform 60 :accessor oauth-state-expire)))

(defmethod clack.component:call ((this <clack-middleware-oauth>) req)
  (if (not (string-equal (oauth-path this) (getf req :path-info)))
      (call-next this req)
      (authorize this (make-request req))))

(defmethod obtain-request-token-from-provider ((this <clack-middleware-oauth>))
  (let* ((req-token (cl-oauth:obtain-request-token
                     (oauth-request-token-uri this)
                     (cl-oauth:make-consumer-token
                      :key (oauth-consumer-key this)
                      :secret (oauth-consumer-secret this))
                     :callback-uri (format nil "~a~a" (oauth-callback-base this) (oauth-path this))))
         (state (oauth-state this))
         (oauth-token (cl-oauth:token-key req-token)))
    (when (gethash (cl-oauth:token-key req-token) state)
      (error "OAuth request token collision is detected."))
    (setf (gethash (cl-oauth:token-key req-token) state)
          (list req-token (get-universal-time)))
    req-token))

(defmethod obtain-request-token ((this <clack-middleware-oauth>) req)
  (bind ((oauth-token (query-parameters req "oauth_token"))
         ((req-token time) (gethash oauth-token (oauth-state this))))
    (declare (ignore time))
    req-token))

(defmethod obtain-access-token ((this <clack-middleware-oauth>) req-token)
  (cl-oauth:obtain-access-token (oauth-access-token-uri this) req-token))

(defmethod cleanup-states ((this <clack-middleware-oauth>))
  (let ((now (get-universal-time))
        (state (oauth-state this))
        (expire (oauth-state-expire this)))
    (loop for k being the hash-keys in state using (hash-value v)
          unless (< (- now (second v)) expire)
            do (remhash k state))))

(defmethod is-expired ((this <clack-middleware-oauth>) oauth-token)
  (let ((now (get-universal-time)))
    (not
     (aand (gethash oauth-token (oauth-state this))
           (< (- now (second it)) (oauth-state-expire this))))))

(defmethod is-authorizing ((this <clack-middleware-oauth>) req)
  (let ((oauth-token (query-parameters req "oauth_token"))
        (oauth-verifier (query-parameters req "oauth_verifier")))
    (and oauth-token oauth-verifier
         (not (is-expired this oauth-token)))))

(defmethod authorize ((this <clack-middleware-oauth>) req)
  (cleanup-states this)
  (if (is-authorizing this req)
      (authorize-cont this req)
      (authorize-init this req)))

(defmethod authorize-init ((this <clack-middleware-oauth>) req)
  (let ((req-token (obtain-request-token-from-provider this))
        (res (make-response)))
    (redirect res (cl-oauth:make-authorization-uri (oauth-authorize-uri this) req-token))
    (finalize res)))

(defmethod authorize-cont ((this <clack-middleware-oauth>) req)
  (let ((oauth-token (query-parameters req "oauth_token"))
        (oauth-verifier (query-parameters req "oauth_verifier"))
        (req-token (obtain-request-token this req)))
    (setf (cl-oauth:request-token-verification-code req-token) oauth-verifier)
    (cl-oauth:authorize-request-token req-token)
    (let ((acc-token (obtain-access-token this req-token)))
      (unless (remhash oauth-token (oauth-state this))
        (error "BUG"))
      (funcall (oauth-authorized this) req acc-token))))
