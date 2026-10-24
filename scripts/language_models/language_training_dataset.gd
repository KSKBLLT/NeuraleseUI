extends RefCounted

# Deliberately small, authored examples for the classroom progress simulation.
# They are not the checkpoint's original training corpus.
const META := {
	"name":"language_stories", "size":12, "simulated":true,
	"input_kind":"text", "fully_local":true, "storage":"inline",
	"training_loss":"cross_entropy",
	"description":"Short stories for a language model.",
	"inputs":{"datatype":"text", "x":1},
	"outputs":[{"label":"text", "datatype":"text", "x":1}],
	"input_hints":[{"name":"text", "value":"12 stories", "dtype":"text"}],
	"samples":[
		"The little cat looked out of the window. The rain had stopped. A child opened the door, and they went outside to look for birds in the garden.",
		"A bright sun warmed the quiet garden. The flowers opened slowly. A girl filled a small blue cup with water and gave each flower a drink.",
		"The robot helped a child find a book. They looked on every shelf. At last they found a story about the sea and sat down to read it together.",
		"At school we learn to ask good questions. Today our teacher brought a box of seeds. We planted them in little pots and put them beside the window.",
		"The king and queen walked through the garden. They saw a bird with a hurt wing. The queen made a warm nest, and the king brought water for the bird.",
		"Mother and father read a story together. Their children listened beside the fire. When the story ended, everyone drew a picture of their favourite animal.",
		"The brave girl found a tiny blue bird. It was hiding under a leaf. She waited quietly until its mother came back, then walked home with a smile.",
		"A friendly robot drew a yellow star. A boy asked it to draw the moon too. Soon their paper was full of planets, and they told a story about space.",
		"Rain fell softly on the green leaves. A frog sat by the pond. When the clouds moved away, it jumped into the water and made a little splash.",
		"We learn new words by reading books. My friend chose a book about trains. We read a page each and imagined a journey through the mountains.",
		"The boy shared his toy with a friend. They built a long road from wooden blocks. Their little cars crossed a bridge and stopped beside a red house.",
		"The moon shone over a peaceful town. A child watched it from a bedroom window. She said good night to the stars and fell asleep beside her toy bear."
	],
	"validation_samples":[
		"A little dog waited beside the gate. Its friend came home and gave it a warm hug.",
		"The children took a basket to the park. They ate apples under a tall tree and watched the clouds.",
		"A small boat floated on the lake. A boy held its string while his sister walked along the shore.",
		"The farmer found an egg in the barn. He carried it carefully to the kitchen and made breakfast.",
		"A red bus stopped near the school. The driver opened the door and smiled at the children.",
		"The girl lost her yellow hat. She looked under the table and found her cat sleeping on it.",
		"A young bear wanted some honey. His mother showed him a tall tree with bees near the top.",
		"The baker made a round cake. A child helped to put berries on top before their friends arrived.",
		"Snow covered the path to the house. Two children put on warm coats and built a snowman outside.",
		"A turtle carried a green leaf to the pond. The fish came close to see what it had found.",
		"The family went to the beach. They made a castle in the sand and listened to the waves.",
		"A curious rabbit followed a butterfly. It stopped beside a flower and waited for the butterfly to return."
	]
}
