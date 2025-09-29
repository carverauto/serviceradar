import gleam/io
import gleam/list
import gleam/string

pub fn transpose(matrix: List(List(Int))) -> List(List(Int)) {
  case matrix {
    [] -> []
    [[], ..] -> []
    _ -> {
      let first_column = list.map(matrix, fn(row) {
        case row {
          [head, ..] -> head
          [] -> 0
        }
      })
      let remaining = list.map(matrix, fn(row) {
        case row {
          [_, ..tail] -> tail
          [] -> []
        }
      })
      [first_column, ..transpose(remaining)]
    }
  }
}

pub fn main() -> Nil {
  let matrix = [[1, 2, 3], [4, 5, 6]]
  let transposed = transpose(matrix)
  io.println(string.inspect(transposed))
}
