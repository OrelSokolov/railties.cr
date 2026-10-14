# Attribute parsing 1:1 with Rails::Generators::GeneratedAttribute:
# `name:type` with `{limit}` / `{precision,scale}` modifiers and
# `:index` / `:uniq` suffixes; `references` (+ `{polymorphic}`).

module CRails
  module Generators
    class Field
      getter name : String
      getter type : String
      getter limit : Int32?
      getter precision : Int32?
      getter scale : Int32?
      getter? index : Bool
      getter? uniq : Bool
      getter? polymorphic : Bool

      def initialize(@name, @type, @limit = nil, @precision = nil, @scale = nil,
                     @index = false, @uniq = false, @polymorphic = false)
      end

      def reference? : Bool
        {"references", "belongs_to"}.includes?(@type)
      end

      # Default fixture value per type (mirror of Rails' fixture scaffold).
      def fixture_value : String
        case @type
        when "string"            then "MyString"
        when "text"              then "MyText"
        when "boolean"           then "false"
        when "date"              then "2026-10-05"
        when "datetime", "time"  then "2026-10-05 11:52:37"
        when "float"             then "1.5"
        when "decimal"           then "9.99"
        when "integer", "references", "belongs_to"
          reference? ? singular : "1"
        else "MyString"
        end
      end

      def singular : String
        @name.singularize
      end
    end

    module Fields
      VALID_TYPES = %w[string text integer float decimal datetime timestamp
                       time date boolean references belongs_to]

      class UnknownFieldType < Exception
        getter field : String

        def initialize(@field)
          super("unknown type")
        end
      end

      # `title:string{40}:index` -> Field. Raises UnknownFieldType like Rails.
      def self.parse(raw : String) : Field
        name, rest = raw.split(":", 2)
        rest ||= "string"

        index = false
        uniq = false
        if rest.ends_with?(":index")
          rest = rest[0..-7]
          index = true
        elsif rest.ends_with?(":uniq")
          rest = rest[0..-6]
          uniq = true
        end

        limit = precision = scale = nil
        polymorphic = false
        if braces = rest.match(/\{([^}]*)\}$/)
          rest = rest[0...braces.begin.not_nil!]
          nums = [] of Int32
          braces[1].split(',').each do |mod|
            case
            when mod == "polymorphic"      then polymorphic = true
            when mod == "null"             then # unsupported modifier, ignored
            when mod.includes?(':')             # {default: x} — unsupported
            else
              n = mod.to_i?
              nums << n if n
            end
          end
          if nums.size == 1
            limit = nums[0]
          elsif nums.size >= 2
            precision, scale = nums[0], nums[1]
          end
        end

        raise UnknownFieldType.new(raw) unless VALID_TYPES.includes?(rest)
        Field.new(name, rest, limit, precision, scale, index, uniq, polymorphic)
      end

      def self.parse_all(raws : Array(String)) : Array(Field)
        raws.map { |r| parse(r) }
      end
    end
  end
end
