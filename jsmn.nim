# Copyright 2016 Huy Doan
#
# This file is a Nim fork of Jsmn: https://github.com/zserge/jsmn
# Copyright (c) 2010 Serge A. Zaitsev
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

## This module is a fork of `Jsmn <http://zserge.com/jsmn.html>`_ - a world fastest JSON parser/tokenizer - in pure Nim
##
## It also supports ``PARENT LINKS`` and ``STRICT MODE``, you can enable them via command line switch
##
## Installation
## ============
##.. code-block::
##  nimble install jsmn
##
## Usage
## =====
##.. code-block:: nim
##  import jsmn
##
##  const
##    json = """{
##      "user": "johndoe",
##      "admin": false,
##      "uid": 1000,
##      "groups": ["users", "wheel", "audio", "video"]}"""
##
##  var
##    tokens: array[32, JsmnToken] # expect not more than 32 tokens
##
##  let r = parseJson(json, tokens)
##
##  for i in 1..r:
##    var token = addr tokens[i]
##    echo "Kind: ", token.kind
##    echo "Value: ", json[token.start..<token.stop]

import tables, strutils

type
  JsmnKind* = enum ## JSON type identifier
    JSMN_UNDEFINED, ## Undefined
    JSMN_OBJECT, ## Object, tuple
    JSMN_ARRAY, ## Array, seq
    JSMN_STRING, ## String
    JSMN_PRIMITIVE ## Other primitive: number, boolean (true/false) or null

  JsmnToken* = object
    ## JSON token description.
    kind*: JsmnKind
    start*: int ## start position in JSON data string
    stop*: int ## end position in JSON data string
    size*: int
    when defined(JSMN_PARENT_LINKS):
      parent*: int

  JsmnParser = object
    pos: int
    toknext: int
    toksuper: int

  JsmnException* = object of ValueError

  JsmnNotEnoughTokensException* = object of JsmnException
    ## not enough tokens, JSON string is too large
  JsmnBadTokenException = object of JsmnException
    ## bad token, JSON string is corrupted
  JsmnNotEnoughJsonDataException* = object of JsmnException
    ## JSON string is too short, expecting more JSON data
const
  JSMN_TOKENS = 256

when defined(JSMN_STRICT):
  # In strict mode primitive must be followed by "," or "}" or "]"
  const PRIMITIVE_DELIMITERS = ['\x09', '\x0D', '\x0A', ' ', ',', ']', '}']
else:
  const PRIMITIVE_DELIMITERS = [':', '\x09', '\x0D', '\x0A', ' ', ',', ']', '}']

proc `$`(p: JsmnParser): string =
  "JsmnParser[Position: " & $p.pos  & ", NextTokenIndex: " & $p.toknext & ", SuperTokenIndex: " & $p.toksuper & "]"

proc initToken(parser: var JsmnParser, tokens: var openarray[JsmnToken], kind = JSMN_UNDEFINED, start, stop = -1): ptr JsmnToken =
  ## Allocates a token and fills type and boundaries.
  if parser.toknext >= tokens.len - 1:
    raise newException(JsmnNotEnoughTokensException, $parser)

  result = addr tokens[parser.toknext]
  result.kind = kind
  result.start = start
  result.stop = stop
  result.size = 0
  when defined(JSMN_PARENT_LINKS):
    result.parent = -1

  inc(parser.toknext)

proc parsePrimitive(parser: var JsmnParser, tokens: var openarray[JsmnToken], json: string, length: int) =
  ## Fills next available token with JSON primitive.
  var start = parser.pos
  while parser.pos < length and json[parser.pos] != '\0':
    case json[parser.pos]
    of PRIMITIVE_DELIMITERS:
      when defined(JSMN_PARENT_LINKS):
        var token = initToken(parser, tokens, JSMN_PRIMITIVE, start, parser.pos)
        token.parent = parser.toksuper
        assert tokens[token.parent].kind != JSMN_STRING and tokens[token.parent].kind != JSMN_PRIMITIVE
      else:
        discard initToken(parser, tokens, JSMN_PRIMITIVE, start, parser.pos)
      dec(parser.pos)
      return
    else:
      discard

    if json[parser.pos].ord < 32 or json[parser.pos].ord >= 127:
      raise newException(JsmnBadTokenException, $parser)
    inc(parser.pos)
  when defined(JSMN_STRICT):
    # In strict mode primitive must be followed by a comma/object/array
    raise newException(JsmnBadTokenException, $parser)

proc parseString(parser: var JsmnParser, tokens: var openarray[JsmnToken], json: string, length: int) =
  ## Fills next token with JSON string.
  let start = parser.pos
  inc(parser.pos)
  # Skip starting quote
  while parser.pos < length and json[parser.pos] != '\0':
    let c = json[parser.pos]
    # Quote: end of string
    if c == '"':
      when defined(JSMN_PARENT_LINKS):
        var token = initToken(parser, tokens, JSMN_STRING, start + 1, parser.pos)
        token.parent = parser.toksuper
        assert tokens[token.parent].kind != JSMN_STRING and tokens[token.parent].kind != JSMN_PRIMITIVE
      else:
        discard initToken(parser, tokens, JSMN_STRING, start + 1, parser.pos)
      return
    if c == '\x08' and parser.pos + 1 < length:
      inc(parser.pos)
      case json[parser.pos]     # Allowed escaped symbols
      of '\"', '/', '\x08', 'b', 'f', 'r', 'n', 't':
        discard
      of 'u':
        inc(parser.pos)
        var i = 0
        while i < 4 and parser.pos < length and json[parser.pos] != '\0':
          # If it isn't a hex character we have an error
          if not ((json[parser.pos] >= '0' and json[parser.pos] <= '9') or
              (json[parser.pos] >= 'A' and json[parser.pos] <= 'F') or
              (json[parser.pos] >= 'a' and json[parser.pos] <= 'f')):
            raise newException(JsmnBadTokenException, $parser)
          inc(parser.pos)
          inc(i)
        dec(parser.pos)
      else:
        raise newException(JsmnBadTokenException, $parser)
    inc(parser.pos)
  raise newException(JsmnBadTokenException, $parser)

proc parse(parser: var JsmnParser, tokens: var openarray[JsmnToken], json: string, length: int): int =
  ## Parse JSON string and fill tokens.
  if tokens.len <= 0:
    return 0
  var token: ptr JsmnToken
  var count = parser.toknext
  while parser.pos < length and json[parser.pos] != '\0':
    var kind: JsmnKind
    var c = json[parser.pos]
    case c
    of '{', '[':
      inc(count)
      token = initToken(parser, tokens)
      if parser.toksuper != -1:
        assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
        inc(tokens[parser.toksuper].size)
        when defined(JSMN_PARENT_LINKS):
          token.parent = parser.toksuper
          assert tokens[token.parent].kind != JSMN_STRING and tokens[token.parent].kind != JSMN_PRIMITIVE
      token.kind = (if c == '{': JSMN_OBJECT else: JSMN_ARRAY)
      token.start = parser.pos
      parser.toksuper = parser.toknext - 1
      assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
    of '}', ']':
      kind = (if c == '}': JSMN_OBJECT else: JSMN_ARRAY)
      when defined(JSMN_PARENT_LINKS):
        if parser.toknext < 1:
          raise newException(JsmnBadTokenException, $parser)
        token = addr tokens[parser.toknext - 1]
        while true:
          if token.start != -1 and token.stop == -1:
            if token.kind != kind:
              raise newException(JsmnBadTokenException, $parser)
            token.stop = parser.pos + 1
            parser.toksuper = token.parent
            break
          if token.parent == -1:
            break
          token = addr tokens[token.parent]
      else:
        var i = parser.toknext
        while i >= 0:
          token = addr tokens[i]
          if token.start != -1 and token.stop == -1:
            if token.kind != kind:
              raise newException(JsmnBadTokenException, $parser)
            parser.toksuper = -1
            token.stop = parser.pos + 1
            break
          dec(i)
        # Error if unmatched closing bracket
        if i == -1:
          raise newException(JsmnBadTokenException, $parser)
        while i >= 0:
          token = addr tokens[i]
          if token.start != -1 and token.stop == -1:
            parser.toksuper = i
            assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
            break
          dec(i)
    of '"':
      parseString(parser, tokens, json, length)
      inc(count)
      if parser.toksuper != -1:
        assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
        inc(tokens[parser.toksuper].size)
      discard
    of '\t', '\r', '\x0A', ' ':
      discard
    of ':':
      let i = parser.toknext - 1
      if tokens[i].kind != JSMN_STRING and tokens[i].kind != JSMN_PRIMITIVE:
        parser.toksuper = i
        assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
    of ',':
      if parser.toksuper != -1 and
         tokens[parser.toksuper].kind != JSMN_ARRAY and
         tokens[parser.toksuper].kind != JSMN_OBJECT:
        when defined(JSMN_PARENT_LINKS):
          parser.toksuper = tokens[parser.toksuper].parent
        else:
          var i = parser.toknext - 1
          while i >= 0:
            if tokens[i].kind == JSMN_ARRAY or tokens[i].kind == JSMN_OBJECT:
              if tokens[i].start != -1 and tokens[i].stop == -1:
                parser.toksuper = i
                assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
                break
            dec(i)
    else:
      when defined(JSMN_STRICT):
        # In strict mode primitives are: numbers and booleans
        case c
        of '-', {'0'..'9'}, 't', 'f', 'n':
          # And they must not be keys of the object
          if tokens.len <= 0 and parser.toksuper != -1:
            var t: ptr JsmnToken = addr(tokens[parser.toksuper])
            if t.kind == JSMN_OBJECT or (t.kind == JSMN_STRING and t.size != 0):
              raise newException(JsmnBadTokenException, $parser)
          parsePrimitive(parser, tokens, json, length)
          inc(count)
          if parser.toksuper != -1:
            assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
            inc(tokens[parser.toksuper].size)
        else:
          raise newException(JsmnBadTokenException, $parser)
      else:
        parsePrimitive(parser, tokens, json, length)
        inc(count)
        if parser.toksuper != -1:
          assert tokens[parser.toksuper].kind != JSMN_STRING and tokens[parser.toksuper].kind != JSMN_PRIMITIVE
          inc(tokens[parser.toksuper].size)
    inc(parser.pos)

  var i = parser.toknext - 1
  while i >= 0:
    # Unmatched opened object or array
    if tokens[i].start != -1 and tokens[i].stop == -1:
      raise newException(JsmnNotEnoughJsonDataException, $parser)
    dec(i)
  return count

proc parseJson*(json: string, tokens: var openarray[JsmnToken]): int =
  ## Parse a JSON data string into and array of tokens, each describing a single JSON object.
  var parser: JsmnParser
  parser.pos = 0
  parser.toknext = 0
  parser.toksuper = -1
  parser.parse(tokens, json, json.len)

proc parseJson*(json: string): seq[JsmnToken] =
  ## Parse a JSON data and returns a sequence of tokens
  var tokens = newSeq[JsmnToken](JSMN_TOKENS)
  var ret = parseJson(json, tokens)
  while ret < 0:
    setLen(tokens, tokens.len * 2)
    ret = parseJson(json, tokens)

proc getValue(t: JsmnToken, json: string): string =
  json[t.start..<t.stop]

proc loadObject*(target: var auto, tokens: openarray[JsmnToken], json: string, start = 0) {.inline.}

proc loadValue[T: object|tuple](t: openarray[JsmnToken], idx: int, json: string, v: var T) {.inline.} =
  loadObject(v, t, json, idx)

proc loadValue(t: openarray[JsmnToken], idx: int, json: string, v: var bool) {.inline.} =
  let value = t[idx].getValue(json)
  v = value[0] == 't'

proc loadValue(t: openarray[JsmnToken], idx: int, json: string, v: var char) {.inline.} =
  let value = t[idx].getValue(json)
  if value.len > 0:
    v = value[0]

proc loadValue[T: int|int8|int16|int32|int64|uint|uint8|uint16|uint32|uint64|BiggestInt](t: openarray[JsmnToken], idx: int, json: string, v: var T) {.inline.} =
  when v is int:
    v = parseInt(t[idx].getValue(json))
  else:
    v = (T)parseInt(t[idx].getValue(json))


proc loadValue[T: float|float32|float64|BiggestFloat](t: openarray[JsmnToken], idx: int, json: string, v: var T) {.inline.} =
  when v is float:
    v = parseFloat(t[idx].getValue(json))
  else:
    v = (T)parseFloat(t[idx].getValue(json))

proc loadValue(t: openarray[JsmnToken], idx: int, json: string, v: var string) {.inline.} =
  if t[idx].kind == JSMN_STRING:
    v = t[idx].getValue(json)

proc loadValue[T: enum](t: openarray[JsmnToken], idx: int, json: string, v: var T) {.inline.} =
  let value = t[idx].getValue(json)
  for e in low(v)..high(v):
    if $e == value:
      v = e

proc loadValue[T: array](t: openarray[JsmnToken], idx: int, json: string, v: var T) {.inline.} =
  for x in 0..<v.len:
    case t[idx + 1].kind
    of JSMN_PRIMITIVE, JSMN_STRING:
      loadValue(t, idx + 1 + x, json, v[x])
    else:
      let size = t[idx+1].size + 1
      loadValue(t, idx + 1 + x * size, json, v[x])

proc loadValue(t: openarray[JsmnToken], idx: int, json: string, v: var seq) {.inline.} =
  newSeq(v, t[idx].size)
  for x in 0..<t[idx].size:
    case t[idx + 1].kind
    of JSMN_PRIMITIVE, JSMN_STRING:
      loadValue(t, idx + 1 + x, json, v[x])
    else:
      let size = t[idx+1].size + 1
      loadValue(t, idx + 1 + x * size, json, v[x])

proc loadObject*(target: var auto, tokens: openarray[JsmnToken], json: string, start = 0) =
  ## reads data and transforms it to ``target``
  var
    i = start
    t: JsmnToken
    key: string
    maps = newTable[string, int](32)

  if tokens[start].kind != JSMN_OBJECT:
    quit("Object expected", QuitFailure)

  while i < tokens.len-1:
    t = tokens[i]
    if t.kind == JSMN_STRING:
      key = t.getValue(json)
      maps[key] = i+1
      case tokens[i+1].kind
      of JSMN_STRING, JSMN_PRIMITIVE:
        inc(i)
      of JSMN_ARRAY, JSMN_OBJECT:
        inc(i, tokens[i+1].size + 1)
      else:
        discard
    inc(i)

  for n, v in fieldPairs(target):
    if maps.hasKey(n):
      echo n, ", ", tokens[maps[n]]
      loadValue(tokens, maps[n], json, v)

when isMainModule:
  const
    json = "{\"user\": \"johndoe\", \"admin\": false, \"uid\": 1000, \"groups\": [\"users\", \"wheel\", \"audio\", \"video\"]}"

  var
    tokens: array[16, JsmnToken]

  let r = parseJson(json, tokens)
  for i in 1..r:
    var token = addr tokens[i]
    echo "Kind: ", token.kind
    echo "Value: ", json[token.start..<token.stop]
