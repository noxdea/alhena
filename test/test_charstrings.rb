# frozen_string_literal: true

require_relative "test_helper"

class CharstringTest < Minitest::Test
  def numbers(*values)
    values.map do |value|
      value >= -107 && value <= 107 ? [value + 139].pack("C") : "\x1c".b + [value].pack("s>")
    end.join.b
  end

  def interpreter(local = [], global = [])
    Alhena::CFF::Charstring.new(local, global, default: 500, nominal: 100)
  end

  def test_width_hints_masks_and_subroutines
    # A declared stem consumes one mask byte, including bytes that look like operators.
    program = numbers(20, 0, 10) + "\x01\x13\x80".b + numbers(0, 0) + "\x15".b + numbers(-107) + "\x0a\x0e".b
    local = [numbers(10, 20) + "\x05\x0b".b]
    machine = interpreter(local)
    path = machine.outline(program)
    assert_equal 120, machine.width
    assert_equal [0.0, 0.0, 10.0, 20.0], path.coordinates
    global = [numbers(5, 5) + "\x05\x0b".b]
    path = interpreter([], global).outline(numbers(0, 0) + "\x15".b + numbers(-107) + "\x1d\x0e".b)
    assert_equal [0.0, 0.0, 5.0, 5.0], path.coordinates
    assert_raises(Alhena::InvalidFont) { interpreter([numbers(-107) + "\x0a\x0b".b]).outline(program) }
    assert_raises(Alhena::InvalidFont) { interpreter.outline(numbers(-107) + "\x0a\x0e".b) }
  end

  def test_all_curve_operators_and_flex
    cases = {
      8 => [10, 0, 10, 10, 10, 0], 24 => [10, 0, 10, 10, 10, 0, 5, 5],
      25 => [5, 5, 10, 0, 10, 10, 10, 0], 26 => [10, 10, 10, 10],
      27 => [10, 10, 10, 10], 30 => [10, 10, 10, 10, 5], 31 => [10, 10, 10, 10, 5],
      34 => [10, 10, 5, 10, 10, 10, 10], 35 => [10, 0, 10, 5, 10, 0, 10, 0, 10, -5, 10, 0, 50],
      36 => [10, 5, 10, 5, 10, 10, 10, -5, 10], 37 => [10, 5, 10, 5, 10, 0, 10, 0, 10, -5, 10]
    }
    cases.each do |operation, values|
      opcode = operation >= 34 ? [12, operation].pack("C2") : [operation].pack("C")
      path = interpreter.outline(numbers(0, 0) + "\x15".b + numbers(*values) + opcode + "\x0e".b)
      assert_includes path.commands, :cubic_to
      assert path.coordinates.all?(&:finite?)
    end
    assert_raises(Alhena::InvalidFont) { interpreter.outline(numbers(0, 0) + "\x15".b + numbers(1) + "\x08\x0e".b) }
  end

  def test_arithmetic_storage_and_fixed_numbers
    program = numbers(2, 3) + "\x0c\x0a".b + numbers(0) + "\x0c\x14".b
    program << numbers(0) << "\x0c\x15".b << numbers(0) << "\x15".b
    program << "\xff".b << [1.5 * 65536].pack("l>") << numbers(2) << "\x05\x0e".b
    path = interpreter.outline(program)
    assert_equal [5.0, 0.0, 6.5, 2.0], path.coordinates
    assert_raises(Alhena::InvalidFont) { interpreter.outline("\x0c\x0a\x0e".b) }
    assert_raises(Alhena::InvalidFont) { interpreter.outline(numbers(*Array.new(49, 1))) }
    assert_raises(Alhena::InvalidFont) { interpreter.outline(numbers(1, 0) + "\x0c\x0c\x0e".b) }
  end
end
