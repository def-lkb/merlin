Can unqualify module located in the same file
  $ $MERLIN single refactor-open -action unqualify -position 4:6 <<EOF
  > module M = struct
  >   let u = ()
  > end
  > open M
  > let u = M.u
  > EOF
  {
    "class": "return",
    "value": [
      {
        "start": {
          "line": 5,
          "col": 8
        },
        "end": {
          "line": 5,
          "col": 11
        },
        "content": "u"
      }
    ],
    "notifications": []
  }

Can unqualify nested modules located in the same file

  $ $MERLIN single refactor-open -action unqualify -position 6:6 <<EOF
  > module M = struct
  >   module N = struct
  >     let u = ()
  >   end
  > end
  > open M.N
  > let u = M.N.u
  > EOF
  {
    "class": "return",
    "value": [
      {
        "start": {
          "line": 7,
          "col": 8
        },
        "end": {
          "line": 7,
          "col": 13
        },
        "content": "u"
      }
    ],
    "notifications": []
  }

Shouldn't return anything, as nothing to unqualify (for multiline identifiers)

  $ $MERLIN single refactor-open -action unqualify -position 1:6 <<EOF
  > open Unix
  > let f x = x.
  >             tms_stime
  > EOF
  {
    "class": "return",
    "value": [],
    "notifications": []
  }

FIXME shouldn't return anything, as nothing to unqualify (for multi-line identifiers)

  $ $MERLIN single refactor-open -action unqualify -position 6:6 <<EOF
  > module M = struct
  >   module N = struct
  >     let u = ()
  >   end
  > end
  > open M
  > let u = N.
  > u
  > EOF
  {
    "class": "return",
    "value": [
      {
        "start": {
          "line": 7,
          "col": 8
        },
        "end": {
          "line": 8,
          "col": 1
        },
        "content": "N.u"
      }
    ],
    "notifications": []
  }


