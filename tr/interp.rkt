#lang typed/racket

#|

Below is an implementation of an interpreter for an
untyped variant of let-zl (ut-letzl-eval).

Problem: change the definitions of Expr and Val to be:

(define-type Expr (U Real Boolean sum less bind ifte String
                     (Pairof Expr Expr) hd tl))
(define-type Val (U Real Boolean (Pairof Val Val)))

and add:

(struct hd ([pr : Expr]) #:transparent)
(struct tl ([pr : Expr]) #:transparent)

The idea is that a pair of expressions represents an
expression that pairs together its arguments and that the
`hd` and `tl` structs represent `car` and `cdr`.

This will trigger a bunch of type errors. Fix them and add
these subexpressions to the second `random-case` in the body
of `random-expr`

      (cons (random-expr (- depth 1) vars)
            (random-expr (- depth 1) vars))

      (hd (random-expr (- depth 1) vars))

      (tl (random-expr (- depth 1) vars))

(which will trigger it to generate expressions with those
forms in it).  That will probably cause some random test
case failures. Fix them.

Note that this is some funny business happening in
letzl-eval in the case for addition and less-than. Here's
how to get your head around it. First, note that there is
some random testing at the end of the file. The function
`check-evals` compares the output of the untyped letzl
interpreter with Racket's output and complains if they are
different. It does this by calling `racket-safe-eval` and
`ut-letzl-safe-eval`. These evaluators run racket's
evaluator and ut-letzl-eval, but catch all exceptions. If an
exception is raised, they return the error message in the
exception. So this means that if you evaluate

  (sum #f 3)

in the letzl interpreter, it is expected to produce an error
message with the exact same text as this expression:

  (+ #f 3)

And, as you can see, it is not a simple error message. And
in typed/racket, the + operation does accepts only
numbers. So the `require/typed` just below here pulls in the
raw, racket/base version of + (and less than), giving it two
different types:

  (All (α) (-> Boolean Val α))

and

  (All (α) (-> Val Boolean α))

As we know from our study of polymorphism, this is a very
strange type.  How can this function produce an α if it has
not been given one? Well, simple: it can't. This means that
is must either not terminate or raise an exception (or throw
to another continuation, but lets not worry about that).  In
this particular case, it turns out that it will raise an
exception. Because the + operation raises an error when it
gets a boolean as the second argument.

Now, we exploit the magic of typed racket's type system to
use racket/base:+r and racket/base:+l in order to get the
right error message in order to satisfy the random tester.

|#

(require/typed
 racket/base
 [(<= racket/base:<=l) (All (α) (-> Boolean Val α))]
 [(<= racket/base:<=r) (All (α) (-> Val Boolean α))]
 [(+ racket/base:+l) (All (α) (-> Boolean Val α))]
 [(+ racket/base:+r) (All (α) (-> Val Boolean α))]
 [exn:fail:contract:variable-id (-> exn:fail:contract:variable Symbol)])

(define-type Expr (U Real Boolean sum less bind ifte String))
(define-type Val (U Real Boolean))
(struct sum ([lhs : Expr] [rhs : Expr]) #:transparent)
(struct less ([lhs : Expr] [rhs : Expr]) #:transparent)
(struct bind ([var : String] [thn : Expr] [els : Expr]) #:transparent)
(struct ifte ([tst : Expr] [thn : Expr] [els : Expr]) #:transparent)

(: ut-letzl-eval (-> Expr Val))
(define (ut-letzl-eval e)
  (match e
    [(? real?) e]
    [(? boolean?) e]
    [(? string?) (error 'eval "free variable: ~a" e)]
    [(sum lhs rhs)
     (define lhs-v (ut-letzl-eval lhs))
     (define rhs-v (ut-letzl-eval rhs))
     (cond
       [(and (real? lhs-v) (real? rhs-v))
        (+ lhs-v rhs-v)]
       [(real? lhs-v)
        (racket/base:+r lhs-v rhs-v)]
       [else
        (racket/base:+l lhs-v rhs-v)])]
    [(less lhs rhs)
     (define lhs-v (ut-letzl-eval lhs))
     (define rhs-v (ut-letzl-eval rhs))
     (cond
       [(and (real? lhs-v) (real? rhs-v))
        (<= lhs-v rhs-v)]
       [(real? lhs-v)
        (racket/base:<=r lhs-v rhs-v)]
       [else
        (racket/base:<=l lhs-v rhs-v)])]
    [(bind var rhs body)
     (ut-letzl-eval (subst var (ut-letzl-eval rhs) body))]
    [(ifte tst thn els)
     (define tst-v (ut-letzl-eval tst))
     (cond
       [(boolean? tst-v)
        (if tst-v
            (ut-letzl-eval thn)
            (ut-letzl-eval els))]
       [else (error 'eval "if got a non-boolean in the test position")])]))

(: subst (-> String Val Expr Expr))
(define (subst x v e)
  (match e
    [(? real?) e]
    [(? boolean?) e]
    [(? string?) (if (equal? x e) v e)]
    [(sum lhs rhs) (sum (subst x v lhs) (subst x v rhs))]
    [(less lhs rhs) (less (subst x v lhs) (subst x v rhs))]
    [(bind y rhs body)
     (if (equal? x y)
         (bind y (subst x v rhs) body)
         (bind y (subst x v rhs) (subst x v body)))]
    [(ifte tst thn els)
     (ifte (subst x v tst)
           (subst x v thn)
           (subst x v els))]))

(: ut-letzl-safe-eval (-> Expr (U Val String)))
(define (ut-letzl-safe-eval expr)
  (with-handlers ([exn:fail? exn-message])
    (ut-letzl-eval expr)))

(define ns (make-base-namespace))

(: racket-safe-eval (-> Expr (U Val String)))
(define (racket-safe-eval expr)
  (parameterize ([current-namespace ns])
    (with-handlers ([exn:fail:contract:variable?
                     (λ ([exn : exn:fail:contract:variable])
                       (define str
                         (~a (exn:fail:contract:variable-id
                              exn)))
                       (format "eval: free variable: ~a"
                               (regexp-replace #rx"^x" str "")))]
                    [exn:fail? exn-message])
      (call-with-values (λ () (eval (to-racket expr)))
                        (λ x
                          (unless (pair? x) (error 'impossible))
                          (cast (car x) Val))))))

(: to-racket (-> Expr Any))
(define (to-racket e)
  (match e
    [(? real?) e]
    [(? boolean?) e]
    [(? string?) (string->symbol (~a "x" e))]
    [(sum lhs rhs) `(+ ,(to-racket lhs) ,(to-racket rhs))]
    [(less lhs rhs) `(<= ,(to-racket lhs) ,(to-racket rhs))]
    [(bind y rhs body)
     `(let ([,(string->symbol (~a "x" y)) ,(to-racket rhs)])
        ,(to-racket body))]
    [(ifte tst thn els)
     `(let ([t ,(to-racket tst)])
        (unless (boolean? t)
          (error 'eval "if got a non-boolean in the test position"))
        (if t
            ,(to-racket thn)
            ,(to-racket els)))]))


(: random-item (All (α) (-> (Pairof α (Listof α)) α)))
(define (random-item choices)
  (list-ref choices (random (length choices))))

(define-syntax-rule
  (random-case e ...)
  ((random-item (list (λ () e) ...))))

(: random-bool (-> Boolean))
(define (random-bool) (random-item (list #f #t)))

(: random-var (-> (Setof String) String))
(define (random-var vars)
  (define var-list (set->list vars))
  (if (or (empty? var-list)
          (zero? (random 10)))
      (random-string)
      (random-item var-list)))

(: random-string (-> String))
(define (random-string) (apply string (random-list-of-chars)))

(: random-list-of-chars (-> (Pairof Char (Listof Char))))
(define (random-list-of-chars)
  (if (zero? (random 3))
      (list (random-char))
      (cons (random-char) (random-list-of-chars))))

(: random-char (-> Char))
(define (random-char) (random-item (list #\a #\b #\c #\τ)))

(: random-real (-> Real))
(define (random-real) (random-item (list -1 1.0 -0.0 5 3/2)))

(: random-expr (-> Natural (Setof String) Expr))
(define (random-expr depth vars)
  (cond
    [(zero? depth)
     (random-case
      (random-real)
      (random-bool)
      (random-var vars))]
    [else
     (random-case
      (random-real)
      (random-bool)
      (random-var vars)
      (sum (random-expr (- depth 1) vars)
           (random-expr (- depth 1) vars))
      (less (random-expr (- depth 1) vars)
            (random-expr (- depth 1) vars))
      (let ([x (random-string)])
        (bind x
              (random-expr (- depth 1) vars)
              (random-expr (- depth 1) (set-add vars x))))
      (ifte (random-expr (- depth 1) vars)
            (random-expr (- depth 1) vars)
            (random-expr (- depth 1) vars)))]))

(: check-evals (-> Expr Void))
(define (check-evals expr)
  (define vr (racket-safe-eval expr))
  (define vl (ut-letzl-safe-eval expr))
  (unless (equal? vr vl)
    (error 'different!
           "\n  ~a\n  produced different results (racket first, letzl second)\n   ~a\n   ~a"
           (regexp-replace #rx"\n" (pretty-format expr) "\n  ")
           (pretty-format vr)
           (pretty-format vl))))

(for ([x (in-range 100)])
  (check-evals (random-expr 4 (set))))