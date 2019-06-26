import 'package:meta/meta.dart';
import 'package:sqlparser/src/ast/ast.dart';
import 'package:sqlparser/src/reader/tokenizer/token.dart';

part 'num_parser.dart';

const _comparisonOperators = [
  TokenType.less,
  TokenType.lessEqual,
  TokenType.more,
  TokenType.moreEqual,
];
const _binaryOperators = const [
  TokenType.shiftLeft,
  TokenType.shiftRight,
  TokenType.ampersand,
  TokenType.pipe,
];

final _startOperators = const [
  TokenType.natural,
  TokenType.left,
  TokenType.inner,
  TokenType.cross
];

class ParsingError implements Exception {
  final Token token;
  final String message;

  ParsingError(this.token, this.message);

  @override
  String toString() {
    return token.span.message('Error: $message}');
  }
}

// todo better error handling and synchronisation, like it's done here:
// https://craftinginterpreters.com/parsing-expressions.html#synchronizing-a-recursive-descent-parser

class Parser {
  final List<Token> tokens;
  final List<ParsingError> errors = [];
  int _current = 0;

  Parser(this.tokens);

  bool get _isAtEnd => _peek.type == TokenType.eof;
  Token get _peek => tokens[_current];
  Token get _previous => tokens[_current - 1];

  bool _match(List<TokenType> types) {
    for (var type in types) {
      if (_check(type)) {
        _advance();
        return true;
      }
    }
    return false;
  }

  bool _matchOne(TokenType type) {
    if (_check(type)) {
      _advance();
      return true;
    }
    return false;
  }

  bool _check(TokenType type) {
    if (_isAtEnd) return false;
    return _peek.type == type;
  }

  Token _advance() {
    if (!_isAtEnd) {
      _current++;
    }
    return _previous;
  }

  @alwaysThrows
  void _error(String message) {
    final error = ParsingError(_peek, message);
    errors.add(error);
    throw error;
  }

  Token _consume(TokenType type, String message) {
    if (_check(type)) return _advance();
    _error(message);
  }

  /// Parses a [SelectStatement], or returns null if there is no select token
  /// after the current position.
  ///
  /// See also:
  /// https://www.sqlite.org/lang_select.html
  SelectStatement select() {
    if (!_match(const [TokenType.select])) return null;

    var distinct = false;
    if (_matchOne(TokenType.distinct)) {
      distinct = true;
    } else if (_matchOne(TokenType.all)) {
      distinct = false;
    }

    final resultColumns = <ResultColumn>[];
    do {
      resultColumns.add(_resultColumn());
    } while (_match(const [TokenType.comma]));

    final from = _from();

    final where = _where();
    final groupBy = _groupBy();
    final orderBy = _orderBy();
    final limit = _limit();

    return SelectStatement(
      distinct: distinct,
      columns: resultColumns,
      from: from,
      where: where,
      groupBy: groupBy,
      orderBy: orderBy,
      limit: limit,
    );
  }

  /// Parses a [ResultColumn] or throws if none is found.
  /// https://www.sqlite.org/syntax/result-column.html
  ResultColumn _resultColumn() {
    if (_match(const [TokenType.star])) {
      return StarResultColumn(null);
    }

    final positionBefore = _current;

    if (_match(const [TokenType.identifier])) {
      // two options. the identifier could be followed by ".*", in which case
      // we have a star result column. If it's followed by anything else, it can
      // still refer to a column in a table as part of a expression result column
      final identifier = _previous;

      if (_match(const [TokenType.dot]) && _match(const [TokenType.star])) {
        return StarResultColumn((identifier as IdentifierToken).identifier);
      }

      // not a star result column. go back and parse the expression.
      // todo this is a bit unorthodox. is there a better way to parse the
      // expression from before?
      _current = positionBefore;
    }

    final expr = expression();
    final as = _as();

    return ExpressionResultColumn(expression: expr, as: as?.identifier);
  }

  /// Returns an identifier followed after an optional "AS" token in sql.
  /// Returns null if there is
  IdentifierToken _as() {
    if (_match(const [TokenType.as])) {
      return _consume(TokenType.identifier, 'Expected an identifier')
          as IdentifierToken;
    } else if (_match(const [TokenType.identifier])) {
      return _previous as IdentifierToken;
    } else {
      return null;
    }
  }

  List<Queryable> _from() {
    if (!_matchOne(TokenType.from)) return [];

    // Can either be a list of <TableOrSubquery> or a join. Joins also start
    // with a TableOrSubquery, so let's first parse that.
    final start = _tableOrSubquery();
    // parse join, if it is one
    final join = _joinClause(start);
    if (join != null) {
      return [join];
    }

    // not a join. Keep the TableOrSubqueries coming!
    final queries = [start];
    while (_matchOne(TokenType.comma)) {
      queries.add(_tableOrSubquery());
    }

    return queries;
  }

  TableOrSubquery _tableOrSubquery() {
    //  this is what we're parsing: https://www.sqlite.org/syntax/table-or-subquery.html
    // we currently only support regular tables and nested selects
    if (_matchOne(TokenType.identifier)) {
      // ignore the schema name, it's not supported. Besides that, we're on the
      // first branch in the diagram here
      final tableName = (_previous as IdentifierToken).identifier;
      final alias = _as();
      return TableReference(tableName, alias?.identifier);
    } else if (_matchOne(TokenType.leftParen)) {
      final innerStmt = select();
      _consume(TokenType.rightParen,
          'Expected a right bracket to terminate the inner select');

      final alias = _as();
      return SelectStatementAsSource(
          statement: innerStmt, as: alias?.identifier);
    }

    _error('Expected a table name or a nested select statement');
  }

  JoinClause _joinClause(TableOrSubquery start) {
    var operator = _parseJoinOperatorNoComma();
    if (operator == null) {
      return null;
    }

    final joins = <Join>[];

    while (operator != null) {
      final subquery = _tableOrSubquery();
      final constraint = _joinConstraint();
      JoinOperator resolvedOperator;
      if (operator.contains(TokenType.left)) {
        resolvedOperator = operator.contains(TokenType.outer)
            ? JoinOperator.leftOuter
            : JoinOperator.left;
      } else if (operator.contains(TokenType.inner)) {
        resolvedOperator = JoinOperator.inner;
      } else if (operator.contains(TokenType.cross)) {
        resolvedOperator = JoinOperator.cross;
      } else if (operator.contains(TokenType.comma)) {
        resolvedOperator = JoinOperator.comma;
      }

      joins.add(Join(
        natural: operator.contains(TokenType.natural),
        operator: resolvedOperator,
        query: subquery,
        constraint: constraint,
      ));

      // parse the next operator, if there is more than one join
      if (_matchOne(TokenType.comma)) {
        operator = [TokenType.comma];
      } else {
        operator = _parseJoinOperatorNoComma();
      }
    }

    return JoinClause(primary: start, joins: joins);
  }

  /// Parses https://www.sqlite.org/syntax/join-operator.html, minus the comma.
  List<TokenType> _parseJoinOperatorNoComma() {
    if (_match(_startOperators)) {
      final operators = [_previous.type];
      // natural is a prefix, another operator can follow.
      if (_previous.type == TokenType.natural) {
        if (_match([TokenType.left, TokenType.inner, TokenType.cross])) {
          operators.add(_previous.type);
        }
      }
      if (_previous.type == TokenType.left && _matchOne(TokenType.outer)) {
        operators.add(_previous.type);
      }

      _consume(TokenType.join, 'Expected to see a join keyword here');
      return operators;
    }
    return null;
  }

  /// Parses https://www.sqlite.org/syntax/join-constraint.html
  JoinConstraint _joinConstraint() {
    if (_matchOne(TokenType.on)) {
      return OnConstraint(expression: expression());
    } else if (_matchOne(TokenType.using)) {
      _consume(TokenType.leftParen, 'Expected an opening paranthesis');

      final columnNames = <String>[];
      do {
        final identifier =
            _consume(TokenType.identifier, 'Expected a column name');
        columnNames.add((identifier as IdentifierToken).identifier);
      } while (_matchOne(TokenType.comma));

      _consume(TokenType.rightParen, 'Expected an closing paranthesis');

      return UsingConstraint(columnNames: columnNames);
    }
    _error('Expected a constraint with ON or USING');
  }

  /// Parses a where clause if there is one at the current position
  Expression _where() {
    if (_match(const [TokenType.where])) {
      return expression();
    }
    return null;
  }

  GroupBy _groupBy() {
    if (_matchOne(TokenType.group)) {
      _consume(TokenType.by, 'Expected a "BY"');
      final by = <Expression>[];
      Expression having;

      do {
        by.add(expression());
      } while (_matchOne(TokenType.comma));

      if (_matchOne(TokenType.having)) {
        having = expression();
      }

      return GroupBy(by: by, having: having);
    }
    return null;
  }

  OrderBy _orderBy() {
    if (_match(const [TokenType.order])) {
      _consume(TokenType.by, 'Expected "BY" after "ORDER" token');
      final terms = <OrderingTerm>[];
      do {
        terms.add(_orderingTerm());
      } while (_matchOne(TokenType.comma));
      return OrderBy(terms: terms);
    }
    return null;
  }

  OrderingTerm _orderingTerm() {
    final expr = expression();

    if (_match(const [TokenType.asc, TokenType.desc])) {
      final mode = _previous.type == TokenType.asc
          ? OrderingMode.ascending
          : OrderingMode.descending;
      return OrderingTerm(expression: expr, orderingMode: mode);
    }

    return OrderingTerm(expression: expr);
  }

  /// Parses a [Limit] clause, or returns null if there is no limit token after
  /// the current position.
  Limit _limit() {
    if (!_match(const [TokenType.limit])) return null;

    final count = expression();
    Token offsetSep;
    Expression offset;

    if (_match(const [TokenType.comma, TokenType.offset])) {
      offsetSep = _previous;
      offset = expression();
    }

    return Limit(count: count, offsetSeparator: offsetSep, offset: offset);
  }

  /* We parse expressions here.
  * Operators have the following precedence:
  *  - + ~ NOT (unary)
  *  || (concatenation)
  *  * / %
  *  + -
  *  << >> & |
  *  < <= > >=
  *  = == != <> IS IS NOT  IN LIKE GLOB MATCH REGEXP
  *  AND
  *  OR
  *  We also treat expressions in parentheses and literals with the highest
  *  priority. Parsing methods are written in ascending precedence, and each
  *  parsing method calls the next higher precedence if unsuccessful.
  *  https://www.sqlite.org/lang_expr.html
  * */

  Expression expression() {
    return _or();
  }

  /// Parses an expression of the form a <T> b, where <T> is in [types] and
  /// both a and b are expressions with a higher precedence parsed from
  /// [higherPrecedence].
  Expression _parseSimpleBinary(
      List<TokenType> types, Expression Function() higherPrecedence) {
    var expression = higherPrecedence();

    while (_match(types)) {
      final operator = _previous;
      final right = higherPrecedence();
      expression = BinaryExpression(expression, operator, right);
    }
    return expression;
  }

  Expression _or() => _parseSimpleBinary(const [TokenType.or], _and);
  Expression _and() => _parseSimpleBinary(const [TokenType.and], _equals);

  Expression _equals() {
    var expression = _comparison();
    final ops = const [
      TokenType.equal,
      TokenType.doubleEqual,
      TokenType.exclamationEqual,
      TokenType.lessMore,
      TokenType.$is,
      TokenType.$in,
      TokenType.like,
      TokenType.glob,
      TokenType.match,
      TokenType.regexp,
    ];

    while (_match(ops)) {
      final operator = _previous;
      if (operator.type == TokenType.$is) {
        final not = _match(const [TokenType.not]);
        // special case: is not expression
        expression = IsExpression(not, expression, _comparison());
      } else {
        expression = BinaryExpression(expression, operator, _comparison());
      }
    }
    return expression;
  }

  Expression _comparison() {
    return _parseSimpleBinary(_comparisonOperators, _binaryOperation);
  }

  Expression _binaryOperation() {
    return _parseSimpleBinary(_binaryOperators, _addition);
  }

  Expression _addition() {
    return _parseSimpleBinary(const [
      TokenType.plus,
      TokenType.minus,
    ], _multiplication);
  }

  Expression _multiplication() {
    return _parseSimpleBinary(const [
      TokenType.star,
      TokenType.slash,
      TokenType.percent,
    ], _concatenation);
  }

  Expression _concatenation() {
    return _parseSimpleBinary(const [TokenType.doublePipe], _unary);
  }

  Expression _unary() {
    if (_match(const [
      TokenType.minus,
      TokenType.plus,
      TokenType.tilde,
      TokenType.not
    ])) {
      final operator = _previous;
      final expression = _unary();
      return UnaryExpression(operator, expression);
    }

    return _postfix();
  }

  Expression _postfix() {
    // todo parse ISNULL, NOTNULL, NOT NULL, etc.
    // I don't even know the precedence ¯\_(ツ)_/¯ (probably not higher than
    // unary)
    return _primary();
  }

  Expression _primary() {
    final token = _advance();
    final type = token.type;
    switch (type) {
      case TokenType.numberLiteral:
        return NumericLiteral(_parseNumber(token.lexeme), token);
      case TokenType.stringLiteral:
        return StringLiteral(token as StringLiteralToken);
      case TokenType.$null:
        return NullLiteral(token);
      case TokenType.$true:
        return BooleanLiteral.withTrue(token);
      case TokenType.$false:
        return BooleanLiteral.withFalse(token);
      // todo CURRENT_TIME, CURRENT_DATE, CURRENT_TIMESTAMP
      case TokenType.leftParen:
        final left = token;
        if (_peek.type == TokenType.select) {
          final stmt = select();
          _consume(TokenType.rightParen, 'Expected a closing bracket');
          return SubQuery(select: stmt);
        } else {
          final expr = expression();
          _consume(TokenType.rightParen, 'Expected a closing bracket');
          return Parentheses(left, expr, _previous);
        }
        break;
      case TokenType.identifier:
        // could be table.column, function(...) or just column
        final first = _previous as IdentifierToken;

        if (_matchOne(TokenType.dot)) {
          final second =
              _consume(TokenType.identifier, 'Expected a column name here')
                  as IdentifierToken;
          return Reference(
              tableName: first.identifier, columnName: second.identifier);
        } else if (_matchOne(TokenType.leftParen)) {
          final parameters = _functionParameters();
          _consume(TokenType.rightParen,
              'Expected closing bracket after argument list');
          return FunctionExpression(
              name: first.identifier, parameters: parameters);
        } else {
          return Reference(columnName: first.identifier);
        }
        break;
      case TokenType.questionMark:
        final mark = _previous;

        if (_matchOne(TokenType.numberLiteral)) {
          return NumberedVariable(mark, _parseNumber(_previous.lexeme).toInt());
        } else {
          return NumberedVariable(mark, null);
        }
        break;
      case TokenType.colon:
        final identifier = _consume(TokenType.identifier,
            'Expected an identifier for the named variable') as IdentifierToken;
        final content = identifier.identifier;
        return ColonNamedVariable(':$content');
      default:
        break;
    }

    // nothing found -> issue error
    _error('Could not parse this expression');
  }

  FunctionParameters _functionParameters() {
    if (_matchOne(TokenType.star)) {
      return const StarFunctionParameter();
    }

    final distinct = _matchOne(TokenType.distinct);
    final parameters = <Expression>[];
    while (_peek.type != TokenType.rightParen) {
      parameters.add(expression());
    }
    return ExprFunctionParameters(distinct: distinct, parameters: parameters);
  }
}
