defmodule Archive.Schemas do
  use Archive.Nif
  @moduledoc false
  # We use this module to store schemas to inject in other modules, since we
  # want to have them available for NimbleOptions-generated docs
  @extract_flags @extract_info |> Enum.map(& &1.flag)
  @extract_doc """
  Controls optional behavior when extracting archive entries to disk.
  Pass all flags you want to enable as a list. The available flags
  and their default behavior is as follows:
  #{Enum.map(@extract_info, fn %{flag: option, default_doc: doc} -> "* `#{inspect(option)}` - #{doc}\n" end)}
  """
  @extract_opts [
    flags: [
      type: {:or, [{:list, {:in, @extract_flags}}, :non_neg_integer]},
      default: [],
      doc: @extract_doc
    ],
    to: [
      type: :string,
      doc:
        "Directory to extract to. Will create any intermediate directories as necessary. Defaults to the current working directory."
    ],
    prefix: [type: :string, doc: "A prefix to apply to each archive entry."]
  ]

  @reader_opts [
    formats: [
      type:
        {:or,
         [
           {:in, [:all | @read_formats]},
           {:list, {:in, @read_formats}},
           keyword_list: [
             only: [
               type: {:list, {:in, @read_formats}}
             ]
           ],
           keyword_list: [
             except: [
               type: {:list, {:in, @read_formats}}
             ]
           ]
         ]},
      default: :all,
      doc: """
      Specifies the archive formats to support when reading. Can be a single format,
      a list of such formats, or a keyword list with either `:only` or `:except` keys
      containing lists of formats. Available reader formats are `#{inspect(@read_formats)}`.
      """
    ],
    filters: [
      type:
        {:or,
         [
           {:in, @read_filters},
           {:list, {:in, @read_filters}},
           keyword_list: [
             only: [
               type: {:list, {:in, @read_filters}}
             ]
           ],
           keyword_list: [
             except: [
               type: {:list, {:in, @read_filters}}
             ]
           ]
         ]},
      default: @read_filters,
      doc: """
      Specifies the filters to support when reading. Can be a single filter,
      a list of such filters, or a keyword list with either `:only` or `:except` keys
      containing lists of filters. Available reader filters are `#{inspect(@read_filters)}`
      """
    ],
    open: [
      type: :string,
      required: true,
      doc: "The path or name of the archive to open."
    ],
    as: [
      type: {:in, [:file, :data, :auto]},
      default: :auto,
      doc:
        "Specifies how to treat the opened archive. Available options are `[:file, :data, :auto]`"
    ]
  ]

  @writer_opts [
    format: [
      type: {:in, @write_formats},
      default: :tar,
      doc: """
      The format to use when writing the archive. Must be one of these supported
      write formats: `#{inspect(@write_formats)}`.
      """
    ],
    filters: [
      type: {:or, [{:in, [:all | @write_filters]}, {:list, {:in, @write_filters}}]},
      default: :none,
      doc: """
      The filters to apply when writing. Can be `:all`, a single filter,
      or a list of such filters. Available write filters are `#{inspect(@write_filters)}`.
      """
    ],
    file: [
      type: :string,
      required: true,
      doc: "The path or name of the file to write the archive to."
    ]
  ]

  # @reader_schema NimbleOptions.new!(@reader_opts)
  # @writer_schema NimbleOptions.new!(@writer_opts)

  @stream_opts [
    writer:
      [
        type: {:or, [:boolean, keyword_list: @writer_opts]},
        default: [format: :tar, filters: :none],
        # keys: @writer_opts,
        subsection: """
        ### Writer Options
        Configures the writer. If true, uses default options. If a keyword list,
        uses the following options:
        """
      ]
      # Need to add this for NimbleOptions to generate docs correctly
      |> then(&if(Mix.env() == :docs, do: Keyword.put(&1, :keys, @writer_opts), else: &1)),
    reader:
      [
        type: {:or, [{:in, [false]}, keyword_list: @reader_opts]},
        default: [formats: @read_formats, filters: @read_filters],
        subsection: """
        ### Reader Options

        Configures the reader. If false, disables reading. If a keyword list,
        uses the following options:
        """
      ]
      # Need to add this for NimbleOptions to generate docs correctly
      |> then(&if(Mix.env() == :docs, do: Keyword.put(&1, :keys, @reader_opts), else: &1))
  ]

  @stream_schema NimbleOptions.new!(@stream_opts)
  @extract_schema NimbleOptions.new!(@extract_opts)
  defmacro __using__(opts) do
    all_schemas = %{
      extract_schema: @extract_schema,
      stream_schema: @stream_schema
      # reader_schema: @reader_schema,
      # writer_schema: @writer_schema
    }

    schemas =
      cond do
        Keyword.get(opts, :only, false) ->
          Enum.filter(all_schemas, fn {k, _v} -> k in opts[:only] end)

        Keyword.get(opts, :except, false) ->
          Enum.reject(all_schemas, fn {k, _v} -> k in opts[:except] end)

        true ->
          all_schemas
      end

    quotes =
      Enum.map(schemas, fn {k, v} ->
        quote do
          Module.put_attribute(unquote(__CALLER__.module), unquote(k), unquote(Macro.escape(v)))
        end
      end)

    quote do
      (unquote_splicing(quotes))
    end
  end
end
